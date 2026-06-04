// OnboardingWindow.swift — First-Launch Onboarding Window
// V1-QUALITY-C2 + V1-QUALITY-POLISH (PKT-346):
// NSWindow shown once on first launch with permission wizard,
// connection setup, and health check test. Sets hasCompletedOnboarding = true on completion.
// D1: Welcome text fix — removed "all"
// D2: Permission triggering — probe before opening Settings for Automation/Contacts
// D3: Connection page rewrite — transport-oriented cards
// D6: Dynamic notification status on welcome page
// PKT-357: F6 welcome header opacity, F7 brand icon, F8 power copy,
//   F9 test connection text, F10 all permissions listed, F11 notification test
// PKT-491: Legal acceptance step — Privacy Policy + ToS summary with checkbox gate

import SwiftUI
import AppKit

/// UserDefaults key for in-progress onboarding step (`OnboardingStep.rawValue`) while `hasCompletedOnboarding` is false.
/// Cleared on wizard completion and when the user resets onboarding from Settings.
enum OnboardingResumeKey {
    static let stepRaw = "onboardingResumeStepRaw"
}

/// Manages the first-launch onboarding NSWindow.
/// Shows a multi-step wizard:
/// Welcome → Legal Acceptance → Auto Permissions → Manual Permissions → Connection → Test Connection.
/// Checks `UserDefaults.bool(forKey: BridgeDefaults.hasCompletedOnboarding)` — skips if true.
@MainActor
public final class OnboardingWindowController {
    private var window: NSWindow?
    private let permissionManager: PermissionManager

    public init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
    }

    /// Show the onboarding window if the user hasn't completed it yet.
    /// Returns immediately if `hasCompletedOnboarding` is true.
    public func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: BridgeDefaults.hasCompletedOnboarding) else {
            print("[Onboarding] Already completed — skipping")
            return
        }
        show()
    }

    /// Force-show the onboarding window (for testing or re-run).
    public func show() {
        let onboardingView = OnboardingView(
            permissionManager: permissionManager,
            onComplete: { [weak self] in
                self?.complete()
            }
        )

        let hostingController = NSHostingController(
            rootView: ZStack { BridgeStage(); onboardingView }
            // v3.7.6: system-tethered appearance — no forced color scheme.
        )

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to The Bridge"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 520, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        // v3.7.6: system-tethered appearance — leave window.appearance UNSET so
        // the wizard follows the system and live-adapts; the dynamic canvas
        // backing tracks the appearance (no white resize flash).
        window.backgroundColor = BridgeTokens.canvasNSColor

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("[Onboarding] Window shown")
    }

    private func complete() {
        UserDefaults.standard.removeObject(forKey: OnboardingResumeKey.stepRaw)
        UserDefaults.standard.set(true, forKey: BridgeDefaults.hasCompletedOnboarding)
        window?.close()
        window = nil
        // PKT-879 (v3.6.4): land the user in the Dashboard, not raw
        // Settings. Posting this notification lets AppDelegate flash the
        // menu-bar icon so the popover is the discovery surface.
        NotificationCenter.default.post(name: .onboardingDidComplete, object: nil)
        print("[Onboarding] Completed — hasCompletedOnboarding = true; posted onboardingDidComplete")
    }
}

// MARK: - Onboarding View

/// Multi-step onboarding wizard:
/// Welcome → Legal Acceptance → Auto Permissions → Manual Permissions → Connection → Test Connection.
struct OnboardingView: View {
    let permissionManager: PermissionManager
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep = Self.loadResumeStep()
    @State private var healthCheckStatus: HealthCheckStatus = .idle
    @State private var showLegacySSE: Bool = false
    @State private var didAutoAdvanceFromAutoStep: Bool = Self.loadDidAutoAdvanceForResumeStep()
    @State private var hasAcceptedLegal: Bool = UserDefaults.standard.bool(forKey: BridgeDefaults.hasAcceptedLegalTerms)

    // Workspace Setup form state
    // Connection Setup provider picker (UEP-004)
    @State private var selectedProvider: AddConnectionProvider = .notion
    @State private var workspaceToken = ""
    @State private var workspaceName = ""
    @State private var isSavingWorkspace = false
    @State private var workspaceError: String?
    @State private var workspaceSaved = false

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case legalAcceptance = 1
        case workspaceSetup = 2
        case autoPermissions = 3
        case manualPermissions = 4
        case connection = 5
        case testConnection = 6
    }

    /// Local MCP port from config (same source as Settings → Advanced → Network).
    private var configuredSSEPort: Int {
        ConfigManager.shared.ssePort
    }

    enum HealthCheckStatus {
        case idle
        case checking
        case success
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // PKT-879: progress + step caption inside the glass head (.ob-head)
            progressHeader
                .padding(.top, 16)
                .padding(.horizontal, 20)

            // Step content — PKT-357 F6: no implicit animation on step transitions (.ob-body)
            ScrollView {
                Group {
                    switch currentStep {
                    case .welcome:
                        welcomeStep
                    case .legalAcceptance:
                        legalAcceptanceStep
                    case .workspaceSetup:
                        workspaceSetupStep
                    case .autoPermissions:
                        autoPermissionsStep
                    case .manualPermissions:
                        manualPermissionsStep
                    case .connection:
                        connectionStep
                    case .testConnection:
                        testConnectionStep
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 20)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            // Navigation foot rail (.ob-foot)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
            navigationButtons
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 18)
        }
        .frame(width: PKT879Onboarding.windowWidth, height: PKT879Onboarding.windowHeight)
        .background(obShellBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .overlay(
            // top rim highlight (.ob inset 0 1px 0 rgba(255,255,255,.12))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.5)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.12), .clear],
                                       startPoint: .top, endPoint: .center), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.6), radius: 50, y: 30)
        .onChange(of: currentStep) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: OnboardingResumeKey.stepRaw)
        }
        .onAppear {
            hasAcceptedLegal = UserDefaults.standard.bool(forKey: BridgeDefaults.hasAcceptedLegalTerms)
        }
    }

    /// The `.ob` card surface — white-alpha glass gradient over raised carbon.
    private var obShellBackground: some View {
        ZStack {
            BridgeTokens.bgRaised
            LinearGradient(
                colors: [Color.white.opacity(0.07), Color.white.opacity(0.02), Color.white.opacity(0.012)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    // MARK: - Progress header (PKT-879)

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Gradient progress bar matching design/onboarding.html
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    BridgeTokens.accent,
                                    BridgeTokens.accentStrong
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progressFraction, height: 4)
                }
            }
            .frame(height: 4)

            HStack {
                Text("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)".uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(BridgeTokens.fg4)
                Spacer()
                Text(stepCaption.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(BridgeTokens.fg4)
            }
            .padding(.top, 1)
        }
    }

    /// Progress as a fraction of the total step count (1-based: at step 1
    /// the bar is 1/7 full, at the final step it's full).
    private var progressFraction: CGFloat {
        let total = max(1, OnboardingStep.allCases.count)
        return CGFloat(currentStep.rawValue + 1) / CGFloat(total)
    }

    private var stepCaption: String {
        switch currentStep {
        case .welcome:           return "Welcome"
        case .legalAcceptance:   return "Privacy & Terms"
        case .workspaceSetup:    return "Connect Workspace"
        case .autoPermissions:   return "Auto Permissions"
        case .manualPermissions: return "Manual Permissions"
        case .connection:        return "Connect a Client"
        case .testConnection:    return "You're Set"
        }
    }

    /// Restores wizard position after quit/relaunch; defaults to welcome when no saved step.
    private static func loadResumeStep() -> OnboardingStep {
        guard let raw = UserDefaults.standard.object(forKey: OnboardingResumeKey.stepRaw) as? Int else {
            return .welcome
        }
        // Migration: old onboarding max was rawValue 5; reset if beyond that
        if raw > 5 {
            UserDefaults.standard.removeObject(forKey: OnboardingResumeKey.stepRaw)
            return .welcome
        }
        return OnboardingStep(rawValue: raw) ?? .welcome
    }

    /// Matches auto-permissions → manual advance so Back/forward behavior stays consistent after resume.
    private static func loadDidAutoAdvanceForResumeStep() -> Bool {
        loadResumeStep().rawValue >= OnboardingStep.manualPermissions.rawValue
    }

    // MARK: - Shared step primitives (matches onboarding.css .ob-hero / .ob-title / .ob-sub / .ob-kp)

    /// 78×78 glass hero tile holding an SF Symbol — accent tint by default,
    /// gold variant for the credential step. Mirrors `.ob-hero`.
    private func obHero(_ systemName: String, tone: HeroTone = .accent) -> some View {
        let tint = tone == .gold ? BridgeTokens.gold : BridgeTokens.accent
        let glyph = tone == .gold ? BridgeTokens.gold : BridgeTokens.accentLink
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.18))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.30), Color.white.opacity(0.06), .clear],
                        center: UnitPoint(x: 0.3, y: 0.18), startRadius: 2, endRadius: 70
                    )
                )
        }
        .frame(width: 78, height: 78)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .inset(by: 0.5)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.40), .clear],
                                       startPoint: .top, endPoint: .center), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.4), radius: 11, y: 8)
        .overlay(
            Image(systemName: systemName)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(glyph)
        )
    }

    private enum HeroTone { case accent, gold }

    /// `.ob-title` — 23pt semibold display title.
    private func obTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 23, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(BridgeTokens.fg1)
            .multilineTextAlignment(.center)
            .opacity(1)
    }

    /// `.ob-sub` — 13.5pt secondary subtitle.
    private func obSub(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(BridgeTokens.fg3)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .frame(maxWidth: 390)
    }

    /// `.ob-kp` — numbered/glyph bullet + key-point text row.
    private func obPointRow(bullet: String, mono: Bool = false, @ViewBuilder text: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(bullet)
                .font(.system(size: mono ? 13 : 12, weight: .semibold))
                .foregroundStyle(BridgeTokens.accentLink)
                .frame(width: 24, height: 24)
                .background(BridgeTokens.accent.opacity(0.22), in: Circle())
            text()
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `.ob-flabel` — uppercase field label.
    private func obFieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(BridgeTokens.fg4)
    }

    // MARK: - Welcome Step (PKT-357: F6, F7, F8)

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            obHero("bridge.fill")
                .padding(.top, 8)

            obTitle("Welcome to The Bridge")
                .padding(.top, 18)

            // PKT-357 F8: Power language — direct, confident, concise
            obSub("One local MCP server for every AI client. Your Mac, fully connected — files, commands, apps, and workflows, all behind your explicit permission.")
                .padding(.top, 14)

            VStack(spacing: 0) {
                obPointRow(bullet: "1") {
                    Text("**Local-first.** Tokens stay on your Mac — zero servers, zero telemetry.")
                }
                .padding(.vertical, 8)
                obPointRow(bullet: "2") {
                    Text("**One surface.** The same tools in every client you connect.")
                }
                .padding(.vertical, 8)
                obPointRow(bullet: "3") {
                    Text("**In control.** Destructive calls need your confirmation.")
                }
                .padding(.vertical, 8)
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Legal Acceptance Step (PKT-491)

    private var legalAcceptanceStep: some View {
        VStack(spacing: 0) {
            obHero("doc.text.fill")
                .padding(.top, 8)

            obTitle("Privacy & Terms")
                .padding(.top, 18)

            obSub("Before we set up permissions, here's how The Bridge handles your data.")
                .padding(.top, 14)

            // Key points summary — carbon inset card
            VStack(alignment: .leading, spacing: 12) {
                legalBullet(
                    icon: "lock.shield.fill",
                    color: BridgeTokens.ok,
                    text: "All data stays on your Mac — zero servers, zero telemetry"
                )
                legalBullet(
                    icon: "network.slash",
                    color: BridgeTokens.accentLink,
                    text: "No data transmitted to us — outbound connections only to services you configure (Notion, Stripe, Cloudflare)"
                )
                legalBullet(
                    icon: "hand.raised.fill",
                    color: BridgeTokens.warn,
                    text: "You control all permissions — deny or revoke any macOS grant at any time"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .padding(.top, 20)

            // Full document links
            HStack(spacing: 18) {
                Link(destination: URL(string: "https://kup.solutions/privacy")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Privacy Policy")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                Link(destination: URL(string: "https://kup.solutions/terms")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Terms of Service")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(BridgeTokens.accentLink)
            .padding(.top, 16)

            // Acceptance checkbox
            Toggle(isOn: $hasAcceptedLegal) {
                Text("I have read and agree to the **Privacy Policy** and **Terms of Service**")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BridgeTokens.fg2)
                    .multilineTextAlignment(.leading)
            }
            .toggleStyle(.checkbox)
            .tint(BridgeTokens.accent)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func legalBullet(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(BridgeTokens.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Workspace Setup Step

    private var workspaceSetupStep: some View {
        VStack(spacing: 0) {
            obHero("key.fill", tone: .gold)
                .padding(.top, 8)

            obTitle("Connect a workspace")
                .padding(.top, 18)

            obSub("Paste a secret. It's stored in your Keychain — never sent anywhere. Add more connections later in Settings.")
                .padding(.top, 14)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    obFieldLabel("Workspace")
                    TextField(selectedProvider.namePlaceholder, text: $workspaceName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    obFieldLabel("Integration token")
                    SecureField(selectedProvider.tokenPlaceholder, text: $workspaceToken)
                        .textContentType(.none)
                        .textFieldStyle(.roundedBorder)
                }

                if let helpURL = selectedProvider.helpURL {
                    Link(destination: helpURL) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text(selectedProvider.helpLabel)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BridgeTokens.accentLink)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)

            if let workspaceError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(BridgeTokens.bad)
                    Text(workspaceError)
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.badText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            }

            if workspaceSaved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BridgeTokens.ok)
                    Text("Workspace connected.")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.okText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func saveWorkspaceConnection() async {
        await MainActor.run {
            isSavingWorkspace = true
            workspaceError = nil
        }

        let trimmedToken = workspaceToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedToken.hasPrefix("ntn_") else {
            await MainActor.run {
                workspaceError = "Invalid token u{2014} must start with ntn_"
                isSavingWorkspace = false
            }
            return
        }

        do {
            _ = try await ConnectionRegistry.shared.configureNotionConnection(
                name: workspaceName,
                token: workspaceToken,
                primary: true
            )
            await MainActor.run {
                workspaceSaved = true
                isSavingWorkspace = false
            }
        } catch {
            await MainActor.run {
                workspaceError = error.localizedDescription
                isSavingWorkspace = false
            }
        }
    }

    // MARK: - Permissions Steps (PKT-388 split)

    private var autoPermissionsStep: some View {
        AutoPermissionsStepView(permissionManager: permissionManager) {
            guard currentStep == .autoPermissions, !didAutoAdvanceFromAutoStep else { return }
            didAutoAdvanceFromAutoStep = true
            currentStep = .manualPermissions
        }
    }

    private var manualPermissionsStep: some View {
        ManualPermissionsStepView(permissionManager: permissionManager)
    }

    // MARK: - Connection Step (D3)

    private var connectionStep: some View {
        VStack(spacing: 0) {
            obTitle("Point a client at Bridge")
                .padding(.top, 10)

            obSub("Paste an endpoint into your AI client\u{2019}s MCP settings.")
                .padding(.top, 14)

            VStack(spacing: 12) {
                // Card 1 — Streamable HTTP (Recommended)
                transportConfigCard(
                    transport: "Streamable HTTP",
                    badge: "Recommended",
                    recommended: true,
                    helperText: "Works with Cursor, Claude Code, and most modern MCP clients. Paste into your client\u{2019}s MCP server configuration.",
                    config: """
                    {
                      "mcpServers": {
                        "notion-bridge": {
                          "url": "http://localhost:\(configuredSSEPort)/mcp"
                        }
                      }
                    }
                    """
                )

                // Card 2 — Legacy SSE (collapsed by default)
                DisclosureGroup(isExpanded: $showLegacySSE) {
                    transportConfigCard(
                        transport: "Legacy SSE",
                        badge: "Legacy",
                        recommended: false,
                        helperText: "For Claude Desktop and clients that use Server-Sent Events. Use this if Streamable HTTP doesn\u{2019}t work with your client.",
                        config: """
                        {
                          "mcpServers": {
                            "notion-bridge": {
                              "url": "http://localhost:\(configuredSSEPort)/sse"
                            }
                          }
                        }
                        """
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(BridgeTokens.fg3)
                        Text("Legacy SSE Transport")
                            .font(.system(size: 12.5))
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                }
                .tint(BridgeTokens.accentLink)
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
    }

    // D3: Transport-oriented config card (matches .ob-tcard / .ob-tcard.rec)
    private func transportConfigCard(transport: String, badge: String?, recommended: Bool, helperText: String, config: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let badge = badge {
                    BridgeBadge(badge, tone: recommended ? .info : .neutral)
                }
                Text(transport)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                Spacer()
            }

            Text(helperText)
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg3)
                .fixedSize(horizontal: false, vertical: true)

            Text(config)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BridgeTokens.fg2)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))

            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(config, forType: .string)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(BridgeTokens.accent)
            }
        }
        .padding(14)
        .background(
            (recommended ? BridgeTokens.accent.opacity(0.10) : Color.black.opacity(0.20)),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(
                recommended ? BridgeTokens.accent.opacity(0.40) : Color.white.opacity(0.10),
                lineWidth: recommended ? 1 : 0.5))
    }

    // MARK: - Test Connection Step (PKT-357 F9: Cleaned up idle text)

    private var testConnectionStep: some View {
        VStack(spacing: 0) {
            // Status medallion — 96px glass circle (matches .ob-check)
            healthMedallion
                .padding(.top, 8)

            obTitle(healthCheckStatus.isSuccess ? "Bridge is up" : "Test the connection")
                .padding(.top, 18)

            // Health check result — PKT-357 F9: Removed misleading "options" text
            Group {
                switch healthCheckStatus {
                case .idle:
                    obSub("Verify that the MCP server is running and reachable from your client.")
                case .checking:
                    obSub("Checking health endpoint\u{2026}")
                case .success:
                    obSub("The Bridge is running and responding. You\u{2019}re ready.")
                case .failed(let reason):
                    Text("Connection check failed: \(reason)")
                        .font(.system(size: 13.5))
                        .foregroundStyle(BridgeTokens.warnText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 390)
                }
            }
            .padding(.top, 14)

            if healthCheckStatus.isSuccess {
                VStack(spacing: 0) {
                    // PKT-879: final step tips lead with the Dashboard (the
                    // menu-bar popover) as the user's landing surface.
                    tipRow(bullet: "▦",
                           text: "The menu bar icon opens the **Dashboard** — status, clients, settings.")
                    .padding(.vertical, 8)
                    tipRow(bullet: "⌘",
                           text: "Press **⌃ ⌥ ⌘ C** to open the **Command Bridge**.")
                    .padding(.vertical, 8)
                    tipRow(bullet: "↗",
                           text: "Destructive actions require approval via notification.")
                    .padding(.vertical, 8)
                }
                .padding(.top, 16)
            } else {
                Button {
                    runHealthCheck()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                        Text(healthCheckButtonLabel)
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(BridgeTokens.accent)
                .controlSize(.large)
                .disabled(healthCheckStatus.isChecking)
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 96pt glass medallion holding the health-check status glyph (matches `.ob-check`).
    @ViewBuilder private var healthMedallion: some View {
        let success = healthCheckStatus.isSuccess
        let tint: Color = {
            switch healthCheckStatus {
            case .success: return BridgeTokens.ok
            case .failed:  return BridgeTokens.warn
            default:       return BridgeTokens.accent
            }
        }()
        ZStack {
            Circle().fill(tint.opacity(0.22))
            Circle().fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.36), Color.white.opacity(0.06), .clear],
                    center: UnitPoint(x: 0.3, y: 0.18), startRadius: 2, endRadius: 80
                )
            )
        }
        .frame(width: 96, height: 96)
        .overlay(Circle().strokeBorder(tint.opacity(0.45), lineWidth: 1.5))
        .shadow(color: success ? BridgeTokens.ok.opacity(0.30) : .black.opacity(0.4),
                radius: success ? 18 : 12, y: success ? 0 : 8)
        .overlay {
            switch healthCheckStatus {
            case .checking:
                ProgressView().scaleEffect(1.3)
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(BridgeTokens.okText)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(BridgeTokens.warnText)
            case .idle:
                Image(systemName: "network")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(BridgeTokens.accentLink)
            }
        }
    }

    private var healthCheckButtonLabel: String {
        switch healthCheckStatus {
        case .idle: return "Test Connection"
        case .checking: return "Checking..."
        case .success: return "Connected \u{2713}"
        case .failed: return "Retry"
        }
    }

    private func runHealthCheck() {
        healthCheckStatus = .checking
        Task {
            do {
                let url = URL(string: "http://localhost:\(configuredSSEPort)/health")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    healthCheckStatus = .failed("Server returned non-200 status")
                    return
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "running" {
                    healthCheckStatus = .success
                } else {
                    healthCheckStatus = .failed("Unexpected response format")
                }
            } catch {
                healthCheckStatus = .failed("Could not reach server \u{2014} is it running?")
            }
        }
    }

    private func tipRow(bullet: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(bullet)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BridgeTokens.accentLink)
                .frame(width: 24, height: 24)
                .background(BridgeTokens.accent.opacity(0.22), in: Circle())
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Navigation (PKT-357 F6: Removed withAnimation to prevent header fade)

    private var navigationButtons: some View {
        HStack(spacing: 8) {
            if currentStep != .welcome {
                footSecondaryButton("Back") {
                    // PKT-357 F6: No animation — prevents welcome header opacity fade
                    currentStep = OnboardingStep(rawValue: currentStep.rawValue - 1) ?? .welcome
                }
            }

            // Workspace step exposes a "Skip for now" secondary (matches design).
            if currentStep == .workspaceSetup, !workspaceSaved {
                footSecondaryButton("Skip for now") {
                    currentStep = OnboardingStep(rawValue: currentStep.rawValue + 1) ?? .testConnection
                }
            }

            Spacer()

            primaryNavButton
        }
    }

    /// The accent primary CTA — label + action vary per step. Binding logic
    /// (legal acceptance, workspace save/advance, completion) preserved verbatim.
    @ViewBuilder private var primaryNavButton: some View {
        switch currentStep {
        case .workspaceSetup:
            if workspaceSaved {
                footPrimaryButton("Continue") {
                    currentStep = OnboardingStep(rawValue: currentStep.rawValue + 1) ?? .testConnection
                }
            } else {
                footPrimaryButton(
                    isSavingWorkspace ? "Saving\u{2026}" : "Save & Continue",
                    disabled: workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || workspaceToken.isEmpty
                        || isSavingWorkspace
                ) {
                    Task { await saveWorkspaceConnection() }
                }
            }
        case .testConnection:
            // PKT-879: explicit "lands user in the Dashboard" CTA.
            footPrimaryButton("Open Bridge") { onComplete() }
        default:
            footPrimaryButton(
                currentStep == .welcome ? "Get started" : "Continue",
                // PKT-491: Gate Continue on legal acceptance
                disabled: currentStep == .legalAcceptance && !hasAcceptedLegal
            ) {
                // PKT-491: Record legal acceptance when advancing past legal step
                if currentStep == .legalAcceptance {
                    UserDefaults.standard.set(true, forKey: BridgeDefaults.hasAcceptedLegalTerms)
                    UserDefaults.standard.set(Date().ISO8601Format(), forKey: "legalAcceptanceDate")
                    print("[Onboarding] Legal terms accepted at \(Date().ISO8601Format())")
                }
                // PKT-357 F6: No animation — prevents welcome header opacity fade
                currentStep = OnboardingStep(rawValue: currentStep.rawValue + 1) ?? .testConnection
            }
        }
    }

    private func footPrimaryButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(BridgeTokens.accent)
            .disabled(disabled)
    }

    private func footSecondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .controlSize(.large)
            .foregroundStyle(BridgeTokens.fg3)
    }
}

// MARK: - HealthCheckStatus Helpers

extension OnboardingView.HealthCheckStatus {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

// MARK: - PKT-879 constants surface (pinned by tests)

/// Locked layout / step-count contract for the v3.6.4 onboarding refresh.
public enum PKT879Onboarding {
    /// Window width per design/onboarding.html (540pt mock; we use 520
    /// to match the existing OnboardingWindowController frame).
    public static let windowWidth: CGFloat = 520

    /// Window height per design/onboarding.html (520pt mock; we use 520
    /// to match the existing OnboardingWindowController frame).
    public static let windowHeight: CGFloat = 520

    /// Locked step count. The mock spec is "Step N of 7".
    public static let totalSteps: Int = 7

    /// The transport that wears the "Recommended" badge on step 6.
    /// Pinned: Streamable HTTP (stdio's modern successor).
    public static let recommendedTransport: String = "Streamable HTTP"
}
