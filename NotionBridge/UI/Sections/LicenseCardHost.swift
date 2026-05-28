// LicenseCardHost.swift — PKT-909 (Sell/Distribute v3 · 1) W3
// NotionBridge · UI · Sections
//
// Bridges the `LicenseManager` actor into a SwiftUI ObservableObject so
// the Settings → Advanced → License card stays reactive without forcing
// every parent view to learn about the actor.
//
// Lifecycle:
//   • SwiftUI host instantiates `@StateObject var host = LicenseCardHost()`.
//   • `.task { await host.load() }` populates initial state from the
//      shared LicenseManager.
//   • All button intents (`activate`, `deactivate`, `buy`) are async +
//     `@MainActor` so error messages land back on the main thread.
//
// HONEST-LEDGER: this object isn't actor-isolated — it's a MainActor
// `@Published` snapshot in front of the actor. The actor remains the
// single source of truth for licensing decisions; this is just the
// SwiftUI render shim.

import Foundation
import SwiftUI
import AppKit

@MainActor
public final class LicenseCardHost: ObservableObject {
    @Published public var uiState: LicenseUIState
    @Published public var pasteField: String = ""

    public init() {
        // Default snapshot before .task fires — a 30-day trial is the
        // honest fresh-install default and renders correctly under
        // SwiftUI previews.
        self.uiState = LicenseUIState(
            kind: .trial(daysRemaining: 30),
            lastError: nil,
            canPasteActivate: false
        )
    }

    /// Refresh from the shared LicenseManager. Safe to call repeatedly;
    /// the actor is the SSoT.
    public func load() async {
        let status = await LicenseManager.shared.currentStatus()
        let canPaste = (LicensePublicKey.bundled() != nil)
        self.uiState = LicenseUIState.from(status, canPasteActivate: canPaste, lastError: nil)
    }

    /// Try to activate the trimmed paste-field as a license token.
    public func activate() async {
        let token = pasteField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            let status = try await LicenseManager.shared.activate(token: token)
            self.pasteField = ""
            self.uiState = LicenseUIState.from(status,
                                               canPasteActivate: (LicensePublicKey.bundled() != nil),
                                               lastError: nil)
            // Notify other Bridge surfaces (Dashboard, MCP gate).
            NotificationCenter.default.post(name: .licenseStateDidChange, object: nil)
        } catch {
            self.uiState = LicenseUIState.from(
                await LicenseManager.shared.currentStatus(),
                canPasteActivate: (LicensePublicKey.bundled() != nil),
                lastError: (error as? LicenseVerifyError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    public func deactivate() async {
        do {
            let status = try await LicenseManager.shared.deactivate()
            self.uiState = LicenseUIState.from(status,
                                               canPasteActivate: (LicensePublicKey.bundled() != nil),
                                               lastError: nil)
            NotificationCenter.default.post(name: .licenseStateDidChange, object: nil)
        } catch {
            self.uiState = LicenseUIState.from(
                await LicenseManager.shared.currentStatus(),
                canPasteActivate: (LicensePublicKey.bundled() != nil),
                lastError: error.localizedDescription
            )
        }
    }

    /// Open the store page in the user's default browser. The host
    /// supplies the URL so a future redirect can land without an app
    /// update.
    public func openBuyPage() {
        let url = URL(string: "https://kup.solutions/notion-bridge")!
        NSWorkspace.shared.open(url)
    }
}

public extension Notification.Name {
    /// Posted on activation / deactivation so other Bridge surfaces
    /// (Dashboard, menu-bar status, MCP gate) can refresh without
    /// polling LicenseManager.
    static let licenseStateDidChange = Notification.Name("com.notionbridge.licenseStateDidChange")
}
