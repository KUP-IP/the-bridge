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
        // Content size matches the SwiftUI root frame + design `.win` (520×520);
        // a shorter NSWindow would clip/compress the foot rail (PKT QA: onboarding).
        window.setContentSize(NSSize(width: 520, height: 520))
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
                .fill(BridgeTokens.hairline)
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
                .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5)
        )
        .overlay(
            // top rim highlight (.ob inset 0 1px 0 rgba(255,255,255,.12))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.5)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.12), .clear],
                                       startPoint: .top, endPoint: .center), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        // `.win` box-shadow → the e4 window elevation rung (dual ambient+contact).
        .bridgeShadow(BridgeTokens.shadowE4)
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
                        .fill(BridgeTokens.chipFill)
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
                .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 1)
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

    /// `.ob-hero.logo` — the welcome medallion carrying the app icon itself
    /// (78×78, continuous-19 radius, dropped shadow, inner rim). Mirrors the
    /// design's brand tile rather than a generic glyph.
    private func obLogoHero() -> some View {
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        return Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 78, height: 78)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.45), radius: 11, y: 8)
    }

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

    /// Secure twin of `.ob-input` (W2 `BridgeInput` has no masked variant):
    /// a `SecureField` in the same inset-well glass chrome — `wellFill` +
    /// `bevelInset` + `.5px` hairline, `input` radius, mono face, accent-strong
    /// caret. Used only for the secret token field.
    private func obSecureField(_ placeholder: String, text: Binding<String>) -> some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous)
        return SecureField(placeholder, text: text)
            .textContentType(.none)
            .textFieldStyle(.plain)
            .font(BridgeTokens.Typeface.mono)
            .foregroundStyle(BridgeTokens.fg1)
            .tint(BridgeTokens.accentStrong)
            .frame(height: 32)
            .padding(.horizontal, 11)
            .background(shape.fill(BridgeTokens.wellFill))
            .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.input)
            .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    // MARK: - Welcome Step (PKT-357: F6, F7, F8)

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            obLogoHero()
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
        // Step 2 is the tallest stack — mirror the design's `.ob-body.t2` compressed
        // rhythm (title 12 / sub 9 / inset 12 + gap 8 / links 10 / check 10) so the
        // gating checkbox always fits the fixed 520×520 window without scrolling.
        VStack(spacing: 0) {
            obHero("doc.text.fill")
                .padding(.top, 8)

            obTitle("Privacy & Terms")
                .padding(.top, 12)

            obSub("Before we set up permissions, here's how The Bridge handles your data.")
                .padding(.top, 9)

            // Key points summary — carbon inset card (`.t2 .ob-inset`: gap 8, padding 10/12)
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            .padding(.top, 12)

            // Full document links — `.ob-links a` → v4 `.btn.link` (accent-link;
            // the variant supplies the trailing ↗ external glyph).
            HStack(spacing: 18) {
                BridgeButton("Privacy Policy", variant: .link) {
                    NSWorkspace.shared.open(URL(string: "https://kup.solutions/privacy")!)
                }
                BridgeButton("Terms of Service", variant: .link) {
                    NSWorkspace.shared.open(URL(string: "https://kup.solutions/terms")!)
                }
            }
            .padding(.top, 10)

            // Acceptance checkbox — `.ob-check-row`: native checkbox (binding +
            // a11y trait preserved) inside an accent-tinted gate row.
            Toggle(isOn: $hasAcceptedLegal) {
                Text("I have read and agree to the **Privacy Policy** and **Terms of Service**")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BridgeTokens.fg2)
                    .multilineTextAlignment(.leading)
            }
            .toggleStyle(.checkbox)
            .tint(BridgeTokens.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BridgeTokens.accent.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(BridgeTokens.accentBorder, lineWidth: 0.5))
            .padding(.top, 10)
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
                    // `.ob-input` — v4 inset-well field (W2 BridgeInput).
                    BridgeInput(selectedProvider.namePlaceholder, text: $workspaceName)
                }

                VStack(alignment: .leading, spacing: 6) {
                    obFieldLabel("Integration token")
                    // Secret token: BridgeInput has no secure variant, so this
                    // wraps SecureField in the same `.ob-input` glass-well chrome
                    // (wellFill + bevelInset + hairline, mono caret = accentStrong).
                    obSecureField(selectedProvider.tokenPlaceholder, text: $workspaceToken)
                }

                if let helpURL = selectedProvider.helpURL {
                    // `.ob-help` external link — v4 `.btn.link` (trailing ↗).
                    BridgeButton(selectedProvider.helpLabel, variant: .link) {
                        NSWorkspace.shared.open(helpURL)
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

    // MARK: - Permissions Steps (PKT-388 split, v4 glass rebuild)
    // Steps 4 & 5 now render inline V4 glass rows (`.ob-prow` idiom) instead of
    // the legacy native AutoPermissionsStepView/ManualPermissionsStepView. The
    // hero/title/sub + `.ob-progress-note` match design/.../onboarding.html steps
    // 4–5, and the step caption comes from the wizard progress header (no more
    // stale "Step 2/3" headings). All PermissionManager wiring is preserved.

    private var autoPermissionsStep: some View {
        OnboardingAutoPermissionsStep(permissionManager: permissionManager) {
            guard currentStep == .autoPermissions, !didAutoAdvanceFromAutoStep else { return }
            didAutoAdvanceFromAutoStep = true
            currentStep = .manualPermissions
        }
    }

    private var manualPermissionsStep: some View {
        OnboardingManualPermissionsStep(permissionManager: permissionManager)
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
                .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))

            HStack {
                Spacer()
                // `.ob-tcopy .btn.sm` — raised-glass copy action (W2 BridgeButton).
                BridgeButton("Copy", systemImage: "doc.on.doc", variant: .default) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(config, forType: .string)
                }
            }
        }
        .padding(14)
        .background(
            (recommended ? BridgeTokens.accent.opacity(0.10) : BridgeTokens.wellFill),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(
                recommended ? BridgeTokens.accent.opacity(0.40) : BridgeTokens.hairline,
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
                           text: "Press **⌃ ⌘ B** anywhere to open the **Command Bridge**.")
                    .padding(.vertical, 8)
                    tipRow(bullet: "↗",
                           text: "Destructive actions require approval via notification.")
                    .padding(.vertical, 8)
                }
                .padding(.top, 16)
            } else {
                // `.btn.primary.lg` — the verify CTA (W2 BridgeButton).
                BridgeButton(healthCheckButtonLabel,
                             systemImage: "bolt.fill",
                             variant: .primary,
                             isEnabled: !healthCheckStatus.isChecking) {
                    runHealthCheck()
                }
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

    /// Accent CTA on the foot rail — the v4 `.btn.primary` (translucent-blue
    /// glass). Maps to `BridgeButton(variant: .primary)`.
    private func footPrimaryButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        BridgeButton(title, variant: .primary, isEnabled: !disabled, action: action)
    }

    /// Secondary foot action (Back / Skip) — the design's `.ob-foot .lnk`: a plain
    /// text link (fg3 → fg1 on hover), NO raised-glass chrome and NO external-link
    /// ↗ glyph (that's reserved for the `.link` variant's outbound URLs). Kept local
    /// so we don't repurpose BridgeButton(.link)'s arrow for in-wizard nav.
    private func footSecondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        OBFootLink(title: title, action: action)
    }
}

/// `.ob-foot .lnk` — plain-text foot-nav link. 13px/medium, `fg3` resting,
/// `fg1` on hover, 8×10 hit padding, no glass and no trailing arrow. Mirrors the
/// design's subdued Back/Skip affordance (distinct from the raised-glass `.btn`
/// and from the outbound `.link` variant that carries a ↗).
private struct OBFootLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? BridgeTokens.fg1 : BridgeTokens.fg3)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
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

// MARK: - Onboarding permission-step shared glass primitives (V4)

/// `.ob-prow` — the V4 glass permission row: 28×28 `glass-control` icon tile,
/// name (`fg1`) + one-line description (`fg5`), and a trailing accessory
/// (a `BridgeBadge` status pill on the auto step, an Open `BridgeButton` on the
/// manual step). Inset-well chrome: `wellFill` + `bevelInset` + faint hairline.
private struct OBPermissionRow<Accessory: View>: View {
    let symbol: String
    let name: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 11) {
            // `.pic` — glass-control icon tile, 8-radius, hairline edge.
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(BridgeTokens.glassControl)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(BridgeTokens.fg2)
            }
            .frame(width: 28, height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5)
            )

            // `.pmain` — name + description, left-aligned, flexes.
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(BridgeTokens.Typeface.sub.weight(.medium))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(detail)
                    // `.pd` is 11px/regular; `cap` is 11px/semibold so relax the weight.
                    .font(BridgeTokens.Typeface.cap.weight(.regular))
                    .foregroundStyle(BridgeTokens.fg5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            BridgeTokens.wellFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .bridgeBevel(BridgeTokens.bevelInset, radius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5)
        )
    }
}

/// Shared per-grant glyph + one-line copy for the onboarding permission rows,
/// mirroring the design's `.ob-prow .pic` icons and `.pd` descriptions.
private enum OBGrantPresentation {
    /// Aligned with PermissionView.rowIcon(for:) so the onboarding rows carry the
    /// same per-grant glyphs the rest of the app uses.
    static func symbol(for grant: PermissionManager.Grant) -> String {
        switch grant {
        case .accessibility:   return "accessibility"
        case .automation:      return "gearshape.2"
        case .contacts:        return "person.crop.circle"
        case .notifications:   return "bell.badge"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .fullDiskAccess:  return "internaldrive"
        case .reminders:       return "checklist"
        case .calendar:        return "calendar"
        }
    }

    static func detail(for grant: PermissionManager.Grant) -> String {
        switch grant {
        case .accessibility:   return "UI control \u{00B7} focus \u{00B7} window management"
        case .automation:      return "Drive Messages, Mail, Calendar"
        case .contacts:        return "Look up people for Messages & Mail"
        case .notifications:   return "Approval prompts for destructive actions"
        case .screenRecording: return "Read on-screen UI & capture screenshots"
        case .fullDiskAccess:  return "Read files across protected folders"
        case .reminders:       return "Create & complete your reminders"
        case .calendar:        return "Read & write calendar events"
        }
    }
}

// MARK: - Onboarding: Auto Permissions (V4 glass — PKT-388)

/// Step 4 (`.ob-body.tight`): "Grant access as you go". Bridge prompts macOS for
/// each auto-grantable permission; rows show a live `ok`/`warn`/`bad` badge and a
/// `.ob-progress-note` summary. Functional wiring (probe deferral, Grant-All
/// sequence, didBecomeActive re-probe, `onResolved` auto-advance) is preserved
/// verbatim from the legacy AutoPermissionsStepView.
private struct OnboardingAutoPermissionsStep: View {
    let permissionManager: PermissionManager
    let onResolved: (() -> Void)?

    private enum AutoGrantProgressState { case pending, prompting, granted, denied }

    @State private var isGrantingAll = false
    @State private var progressState: [PermissionManager.Grant: AutoGrantProgressState] = [:]
    /// Defers probes on appear — user taps Re-check or Grant All first
    /// (avoids stale/misleading granted state).
    @State private var userInitiatedProbe = false

    init(permissionManager: PermissionManager, onResolved: (() -> Void)? = nil) {
        self.permissionManager = permissionManager
        self.onResolved = onResolved
    }

    private var autoGrants: [PermissionManager.Grant] {
        PermissionManager.Grant.v1Cases.filter(\.isAutoGrantable)
    }

    private var grantedCount: Int {
        autoGrants.filter { permissionManager.status(for: $0) == .granted }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            obHero("checkmark.shield.fill")
                .padding(.top, 8)

            obTitle("Grant access as you go")
                .padding(.top, 18)

            obSub("Bridge asks macOS for each of these directly. Click Allow when the system prompts \u{2014} we\u{2019}ll move on automatically.")
                .padding(.top, 14)

            // `.ob-perms` — stacked glass permission rows.
            VStack(spacing: 7) {
                ForEach(autoGrants) { grant in
                    autoPermissionRow(for: grant)
                }
            }
            .padding(.top, 18)

            // `.ob-progress-note` — spinner + "N of M granted".
            HStack(spacing: 8) {
                if isGrantingAll {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 13, height: 13)
                }
                Text("\(grantedCount) of \(autoGrants.count) granted \u{2014} approve the macOS prompt")
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)

            // Grant-All / Re-check actions — V4 BridgeButtons.
            HStack(spacing: 8) {
                BridgeButton(isGrantingAll ? "Granting\u{2026}" : "Grant all",
                             variant: .primary,
                             isEnabled: !isGrantingAll) {
                    Task { await runGrantAllSequentially() }
                }
                BridgeButton("Re-check", variant: .default, isEnabled: !isGrantingAll) {
                    Task {
                        userInitiatedProbe = true
                        await permissionManager.recheckAllForTruth()
                        syncProgressFromManager()
                        notifyResolvedIfNeeded()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard userInitiatedProbe else { return }
            Task {
                await permissionManager.recheckAllForTruth()
                syncProgressFromManager()
                notifyResolvedIfNeeded()
            }
        }
    }

    private func autoPermissionRow(for grant: PermissionManager.Grant) -> some View {
        let state = uiState(for: grant)
        let status = permissionManager.status(for: grant)
        return OBPermissionRow(
            symbol: OBGrantPresentation.symbol(for: grant),
            name: grant.displayName,
            detail: OBGrantPresentation.detail(for: grant)
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                BridgeBadge(label(for: state, status: status),
                            tone: badgeTone(for: state),
                            showsDot: true)
                if needsRemediation(status: status), grant.systemSettingsURL != nil {
                    BridgeButton("Open", variant: .link) { openSettings(for: grant) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    // MARK: State machine (preserved verbatim from AutoPermissionsStepView)

    private func uiState(for grant: PermissionManager.Grant) -> AutoGrantProgressState {
        if let inFlightState = progressState[grant], inFlightState == .prompting {
            return inFlightState
        }
        return baselineState(for: grant)
    }

    private func baselineState(for grant: PermissionManager.Grant) -> AutoGrantProgressState {
        if !userInitiatedProbe { return .pending }
        switch permissionManager.status(for: grant) {
        case .granted:
            return .granted
        case .denied, .partiallyGranted, .restartRecommended:
            return .denied
        case .unknown:
            return .pending
        }
    }

    private func syncProgressFromManager() {
        for grant in autoGrants {
            progressState[grant] = baselineState(for: grant)
        }
    }

    private func notifyResolvedIfNeeded() {
        guard autoGrants.allSatisfy({ permissionManager.status(for: $0).isAutoResolvedOnboarding }) else {
            return
        }
        onResolved?()
    }

    private func runGrantAllSequentially() async {
        guard !isGrantingAll else { return }
        userInitiatedProbe = true
        isGrantingAll = true
        defer { isGrantingAll = false }

        await permissionManager.recheckAllForTruth()

        for grant in autoGrants {
            if permissionManager.status(for: grant).isAutoResolvedOnboarding {
                progressState[grant] = baselineState(for: grant)
                continue
            }

            withAnimation {
                progressState[grant] = .prompting
            }

            switch grant {
            case .contacts:
                _ = await permissionManager.requestContactsAccess()
                if permissionManager.status(for: .contacts) != .granted,
                   let url = PermissionManager.Grant.contacts.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
            case .notifications:
                _ = await permissionManager.requestNotificationAccess()
            case .automation:
                await permissionManager.requestAutomationAccess()
            default:
                break
            }

            await permissionManager.recheckAllForTruth()
            withAnimation {
                progressState[grant] = baselineState(for: grant)
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        syncProgressFromManager()
        notifyResolvedIfNeeded()
    }

    // MARK: Presentation

    private func badgeTone(for state: AutoGrantProgressState) -> BridgeBadge.Tone {
        switch state {
        case .pending, .prompting: return .warn
        case .granted:             return .ok
        case .denied:              return .bad
        }
    }

    private func label(for state: AutoGrantProgressState, status: PermissionManager.GrantStatus) -> String {
        switch state {
        case .pending:
            return userInitiatedProbe ? "Pending" : "Not verified"
        case .prompting: return "Waiting\u{2026}"
        case .granted: return "Granted"
        case .denied:
            if status == .partiallyGranted { return "Partial" }
            return "Denied"
        }
    }

    private func needsRemediation(status: PermissionManager.GrantStatus) -> Bool {
        switch status {
        case .denied, .partiallyGranted:
            return true
        case .granted, .unknown, .restartRecommended:
            return false
        }
    }

    private func openSettings(for grant: PermissionManager.Grant) {
        guard let url = grant.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // Shared V4 hero/title/sub primitives (self-contained — see OnboardingView).
    private func obHero(_ systemName: String) -> some View { OBHero(systemName: systemName, tone: .accent) }
    private func obTitle(_ text: String) -> some View { OBTitle(text: text) }
    private func obSub(_ text: String) -> some View { OBSub(text: text) }
}

// MARK: - Onboarding: Manual Permissions (V4 glass — PKT-388)

/// Step 5 (`.ob-body`): "Two need a manual grant". These can't be requested
/// in-app, so each row opens the exact System Settings pane via an Open
/// `BridgeButton`. A status badge reflects the live grant; an info
/// `.ob-progress-note` reminds the user they can grant later. Wiring (deep-link
/// open, `.task`/didBecomeActive re-probe) is preserved from the legacy view.
private struct OnboardingManualPermissionsStep: View {
    let permissionManager: PermissionManager

    private var manualGrants: [PermissionManager.Grant] {
        PermissionManager.Grant.v1Cases.filter { !$0.isAutoGrantable }
    }

    /// `.ob-title` copy, agreeing in number with the REAL manual-grant count
    /// ("One needs…" / "N need…"). Spelled-out for small counts, numeric beyond.
    private var manualGrantTitle: String {
        let count = manualGrants.count
        let word: String
        switch count {
        case 1: word = "One"
        case 2: word = "Two"
        case 3: word = "Three"
        case 4: word = "Four"
        case 5: word = "Five"
        default: word = "\(count)"
        }
        let verb = count == 1 ? "needs" : "need"
        return "\(word) \(verb) a manual grant"
    }

    var body: some View {
        VStack(spacing: 0) {
            obHero("gearshape.fill")
                .padding(.top, 8)

            // Title is data-driven off the REAL manual-grant set (5 today), not the
            // design mock's count of 2 — singular/plural agree with manualGrants.count.
            // This step carries 5 rows (vs the mock's 2), so the surrounding rhythm
            // is compressed (design `.tight` rung) to fit 520×520 without scrolling.
            obTitle(manualGrantTitle)
                .padding(.top, 14)

            obSub("These can\u{2019}t be requested in-app. We\u{2019}ll open the exact System Settings pane \u{2014} switch The Bridge on, then come back here.")
                .padding(.top, 9)

            // `.ob-perms` — stacked glass permission rows.
            VStack(spacing: 6) {
                ForEach(manualGrants) { grant in
                    manualPermissionRow(for: grant)
                }
            }
            .padding(.top, 12)

            // `.ob-progress-note` (info) — grant-later reminder.
            HStack(spacing: 8) {
                BridgeStatusDot(.info, size: 9)
                Text("You can grant these later in Settings \u{2192} Security.")
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)

            BridgeButton("Re-check", variant: .default) {
                Task { await permissionManager.recheckAllForTruth() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .task {
            await permissionManager.recheckAllForTruth()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissionManager.recheckAllForTruth() }
        }
    }

    private func manualPermissionRow(for grant: PermissionManager.Grant) -> some View {
        let status = permissionManager.status(for: grant)
        return OBPermissionRow(
            symbol: OBGrantPresentation.symbol(for: grant),
            name: grant.displayName,
            detail: OBGrantPresentation.detail(for: grant)
        ) {
            HStack(spacing: 8) {
                if status == .granted {
                    BridgeBadge("Granted", tone: .ok, showsDot: true)
                }
                // `.ob-prow .btn.sm` — open the exact System Settings pane.
                BridgeButton("Open", variant: .default) {
                    guard let url = grant.systemSettingsURL else { return }
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // Shared V4 hero/title/sub primitives (self-contained — see OnboardingView).
    private func obHero(_ systemName: String) -> some View { OBHero(systemName: systemName, tone: .gold) }
    private func obTitle(_ text: String) -> some View { OBTitle(text: text) }
    private func obSub(_ text: String) -> some View { OBSub(text: text) }
}

// MARK: - Reusable onboarding hero/title/sub (shared by the inline step structs)

/// `.ob-hero` — 78×78 glass hero tile holding an SF Symbol (accent tint by
/// default, gold variant for the manual-grant step). Standalone twin of
/// `OnboardingView.obHero` so the inline step structs are self-contained.
private struct OBHero: View {
    let systemName: String
    enum Tone { case accent, gold }
    var tone: Tone = .accent

    var body: some View {
        let tint = tone == .gold ? BridgeTokens.gold : BridgeTokens.accent
        let glyph = tone == .gold ? BridgeTokens.gold : BridgeTokens.accentLink
        ZStack {
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
                .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 1)
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
}

/// `.ob-title` — 23pt semibold display title.
private struct OBTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 23, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(BridgeTokens.fg1)
            .multilineTextAlignment(.center)
    }
}

/// `.ob-sub` — 13.5pt secondary subtitle.
private struct OBSub: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(BridgeTokens.fg3)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .frame(maxWidth: 390)
    }
}

// MARK: - GrantStatus resolution helper (onboarding auto step)

private extension PermissionManager.GrantStatus {
    /// A grant is "resolved" for onboarding auto-advance once the user has acted
    /// on it (granted/denied/partial) — matches the legacy step's semantics.
    var isAutoResolvedOnboarding: Bool {
        switch self {
        case .granted, .denied, .partiallyGranted:
            return true
        case .unknown, .restartRecommended:
            return false
        }
    }
}
