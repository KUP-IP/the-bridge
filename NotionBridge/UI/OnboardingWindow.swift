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

        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Notion Bridge"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

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
            // PKT-879: progress + step caption inside the glass head
            progressHeader
                .padding(.top, 16)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

            // Step content — PKT-357 F6: no implicit animation on step transitions
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
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            // Navigation buttons in the foot rail
            Divider()
                .background(Color.white.opacity(0.08))
            navigationButtons
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: PKT879Onboarding.windowWidth, height: PKT879Onboarding.windowHeight)
        .onChange(of: currentStep) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: OnboardingResumeKey.stepRaw)
        }
        .onAppear {
            hasAcceptedLegal = UserDefaults.standard.bool(forKey: BridgeDefaults.hasAcceptedLegalTerms)
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
                                    Color(red: 0.54, green: 0.49, blue: 0.94),
                                    Color(red: 0.70, green: 0.54, blue: 0.93)
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progressFraction, height: 4)
                }
            }
            .frame(height: 4)

            HStack {
                Text("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stepCaption)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
            }
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

    // MARK: - Welcome Step (PKT-357: F6, F7, F8)

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            // PKT-357 F7: Larger brand icon for visual impact
            Image(systemName: "bridge.fill")
                .font(.system(size: 56))
                .foregroundStyle(.purple)

            // PKT-357 F6: Explicit opacity to prevent animation fade-in
            Text("Welcome to Notion Bridge")
                .font(.title)
                .fontWeight(.semibold)
                .opacity(1)

            // PKT-357 F8: Power language — direct, confident, concise
            Text("Your Mac, fully connected to Notion AI. Manage files, execute commands, control apps, and automate workflows through a secure local MCP server. Every action requires your explicit permission.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

        }
    }

    // MARK: - Legal Acceptance Step (PKT-491)

    private var legalAcceptanceStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 40))
                .foregroundStyle(.purple)

            Text("Privacy & Terms")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Before we set up permissions, please review how NotionBridge handles your data.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            // Key points summary
            VStack(alignment: .leading, spacing: 10) {
                legalBullet(
                    icon: "lock.shield.fill",
                    color: .green,
                    text: "All data stays on your Mac — zero servers, zero telemetry"
                )
                legalBullet(
                    icon: "network.slash",
                    color: .blue,
                    text: "No data transmitted to us — outbound connections only to services you configure (Notion, Stripe, Cloudflare)"
                )
                legalBullet(
                    icon: "hand.raised.fill",
                    color: .orange,
                    text: "You control all permissions — deny or revoke any macOS grant at any time"
                )
            }
            .padding(12)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)

            // Full document links
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://kup.solutions/privacy")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Privacy Policy")
                    }
                    .font(.caption)
                }
                Link(destination: URL(string: "https://kup.solutions/terms")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Terms of Service")
                    }
                    .font(.caption)
                }
            }
            .foregroundStyle(.purple)

            // Acceptance checkbox
            HStack(alignment: .top, spacing: 8) {
                Toggle(isOn: $hasAcceptedLegal) {
                    Text("I have read and agree to the **Privacy Policy** and **Terms of Service**")
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                }
                .toggleStyle(.checkbox)
            }
            .padding(.top, 4)
        }
    }

    private func legalBullet(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Workspace Setup Step

    private var workspaceSetupStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.purple)

            Text("Connect a Service")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add your Notion API token to get started. You can add more connections later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 10) {


                if let helpURL = selectedProvider.helpURL {
                    Link(destination: helpURL) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text(selectedProvider.helpLabel)
                        }
                        .font(.caption)
                        .foregroundStyle(.purple)
                    }
                }

                TextField(selectedProvider.namePlaceholder, text: $workspaceName)
                    .textFieldStyle(.roundedBorder)

                SecureField(selectedProvider.tokenPlaceholder, text: $workspaceToken)
                .textContentType(.none)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 8)

            if let workspaceError {
                Text(workspaceError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if workspaceSaved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Workspace connected!")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 16) {
                if !workspaceSaved {
                    Button("Save & Continue") {
                        Task { await saveWorkspaceConnection() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(
                        workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || workspaceToken.isEmpty
                        || isSavingWorkspace
                    )
                }

                if workspaceSaved {
                    Button("Continue") {
                        currentStep = OnboardingStep(rawValue: currentStep.rawValue + 1) ?? .testConnection
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .font(.callout)
                } else {
                    Button("Skip for now") {
                        currentStep = OnboardingStep(rawValue: currentStep.rawValue + 1) ?? .testConnection
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
            }
        }
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
        VStack(spacing: 16) {
            Text("Connect to Notion Bridge")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Copy the connection config and paste it into your AI client\u{2019}s MCP settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                // Card 1 — Streamable HTTP (Recommended)
                transportConfigCard(
                    transport: "Streamable HTTP",
                    badge: "Recommended",
                    badgeColor: .green,
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
                        badge: nil,
                        badgeColor: .clear,
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
                            .foregroundStyle(.secondary)
                        Text("Legacy SSE Transport")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // D3: Transport-oriented config card (replaces client-named clientConfigCard)
    private func transportConfigCard(transport: String, badge: String?, badgeColor: Color, helperText: String, config: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(transport)
                    .font(.callout)
                    .fontWeight(.medium)
                if let badge = badge {
                    Text(badge)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor)
                        .cornerRadius(4)
                }
                Spacer()
                Button("Copy Config") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(config, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(helperText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(config)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Test Connection Step (PKT-357 F9: Cleaned up idle text)

    private var testConnectionStep: some View {
        VStack(spacing: 20) {
            // Status icon
            Group {
                switch healthCheckStatus {
                case .idle:
                    Image(systemName: "network")
                        .font(.system(size: 48))
                        .foregroundStyle(.gray)
                case .checking:
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(height: 48)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                }
            }

            Text("Test Connection")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Make sure Notion Bridge is running and your client can reach it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            // Health check result — PKT-357 F9: Removed misleading "options" text
            Group {
                switch healthCheckStatus {
                case .idle:
                    Text("Verify that the MCP server is running and reachable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .checking:
                    Text("Checking health endpoint...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .success:
                    Text("Notion Bridge is running and responding! You\u{2019}re all set.")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let reason):
                    Text("Connection check failed: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

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
            .tint(healthCheckStatus.isSuccess ? .green : .purple)
            .disabled(healthCheckStatus.isChecking)

            if healthCheckStatus.isSuccess {
                VStack(alignment: .leading, spacing: 8) {
                    // PKT-879: final step tips lead with the Dashboard (the
                    // menu-bar popover) as the user's landing surface.
                    tipRow(icon: "menubar.arrow.up.rectangle",
                           text: "The menu bar icon opens the Dashboard \u{2014} status, clients, settings")
                    tipRow(icon: "command",
                           text: "Press \u{2318}\u{2325}\u{2303}C to open the Command Bridge")
                    tipRow(icon: "shield.checkered",
                           text: "Destructive actions require approval via notification")
                }
                .padding(.top, 4)
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

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.purple)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Navigation (PKT-357 F6: Removed withAnimation to prevent header fade)

    private var navigationButtons: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    // PKT-357 F6: No animation — prevents welcome header opacity fade
                    currentStep = OnboardingStep(rawValue: currentStep.rawValue - 1) ?? .welcome
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if currentStep == .workspaceSetup {
                // Workspace step has its own Save & Skip buttons
                EmptyView()
            } else if currentStep == .testConnection {
                // PKT-879: explicit "lands user in the Dashboard" CTA.
                Button("Open Bridge") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            } else {
                Button("Continue") {
                    // PKT-491: Record legal acceptance when advancing past legal step
                    if currentStep == .legalAcceptance {
                        UserDefaults.standard.set(true, forKey: BridgeDefaults.hasAcceptedLegalTerms)
                        UserDefaults.standard.set(Date().ISO8601Format(), forKey: "legalAcceptanceDate")
                        print("[Onboarding] Legal terms accepted at \(Date().ISO8601Format())")
                    }
                    // PKT-357 F6: No animation — prevents welcome header opacity fade
                    currentStep = OnboardingStep(rawValue: currentStep.rawValue + 1) ?? .testConnection
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                // PKT-491: Gate Continue on legal acceptance
                .disabled(currentStep == .legalAcceptance && !hasAcceptedLegal)
            }
        }
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
