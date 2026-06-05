// BridgeAutomationModule.swift — On-device automation kit
// NotionBridge · Modules
//
// FB-AUTOMATION (2026-06-04). Closes three deterministic-automation gaps that
// agents hit when driving The Bridge's own Settings UI through the synthetic-
// input + screen tools:
//
//   1. bridge_settings_navigate(section) — read-only nav driver. Opens the
//      Settings window deep-linked to a named section by calling the in-app
//      `SettingsNavigation.shared.go(...)` selection model (the same path the
//      menu-bar quick-page and Dashboard rows use). Agents previously had to
//      synthesise AX presses on unlabeled NavigationSplitView sidebar buttons;
//      this routes deterministically by stable section identity instead.
//
//   2. bridge_focus_settings — brings the Settings window frontmost + raises it.
//      The app is `LSUIElement` (accessory), so when it deactivates the Settings
//      window can drop behind other apps and `screen_capture` of it returns the
//      wrong content. This flips the activation policy to `.regular`, activates
//      the app, and `orderFrontRegardless()` the Settings window so a capture
//      that follows reliably sees it.
//
// Both tools hop to the main actor (all the UI state they touch — the
// `SettingsNavigation` ObservableObject, `NSApp`, `NSWindow`, the
// `SettingsWindowController`) is `@MainActor`-isolated. The handlers are
// `@Sendable` and reach the live AppDelegate via `NSApp.delegate`.
//
// Coordinate-space note (item 3 of the kit): `mouse_click` already consumes
// absolute screen points with a top-left origin, which is the SAME space AX
// reports element position/size in. `screen_capture` is the odd one out — it
// returns 2x device pixels. The deterministic fix lives in MouseClickModule
// (the `axPath` click resolves an element's AX rect and clicks its logical-
// point centre) and in ScreenModule (the `requireFrontmostBundleId` guard).

import Foundation
import AppKit
import MCP

// MARK: - BridgeSettingsAutomation (MainActor core)

/// Main-actor core for the Settings-automation tools. Split out from the tool
/// handlers so the navigation + focus logic is unit-testable without going
/// through the router, and so all the `@MainActor` UI access is in one place.
@MainActor
public enum BridgeSettingsAutomation {

    /// Window title that identifies the Settings window. Mirrors
    /// `SettingsWindowController` ("The Bridge Settings") and the legacy /
    /// SwiftUI titles `WindowTracker` already matches, so a renamed or
    /// SwiftUI-scene Settings window is still found.
    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        let title = window.title
        return title == "The Bridge Settings"
            || title == "Notion Bridge Settings"
            || title == "Settings"
            || title == "Preferences"
            || title.hasSuffix(" Settings")
            || title.hasSuffix(" Preferences")
    }

    /// Resolve a user-supplied section string to a `SettingsSection`.
    /// Accepts the human raw value ("Standing Orders"), the enum case name
    /// ("standingOrders"), and a few common aliases — all case-insensitively
    /// and ignoring spaces — so agents need not know the exact casing.
    public static func resolveSection(_ raw: String) -> SettingsSection? {
        let norm = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard !norm.isEmpty else { return nil }

        for s in SettingsSection.allCases {
            let rawNorm = s.rawValue.lowercased().replacingOccurrences(of: " ", with: "")
            let caseNorm = String(describing: s).lowercased()
            if norm == rawNorm || norm == caseNorm { return s }
        }
        // Common shorthands.
        switch norm {
        case "orders", "standing":     return .standingOrders
        case "command":                return .commands
        case "connection":             return .connections
        case "remote":                 return .remoteAccess
        case "skill":                  return .skills
        case "permission", "privacy":  return .permissions
        case "credential", "vault":    return .credentials
        case "tool":                   return .tools
        case "job":                    return .jobs
        case "settings", "preferences": return nil // ambiguous: not a section
        default:                       return nil
        }
    }

    /// The list of valid section identifiers (raw values) for error messages
    /// and the tool's enum schema.
    public static var sectionRawValues: [String] {
        SettingsSection.allCases.map(\.rawValue)
    }

    /// Drive the in-app navigation to `section`, opening the Settings window if
    /// needed. Returns the resolved section's raw value on success.
    ///
    /// Uses `AppDelegate.openSettings(section:)` when an AppDelegate is present
    /// (production); falls back to mutating the shared selection model directly
    /// (the model is what the view binds to) so the call is still meaningful in
    /// a headless / test context where no AppDelegate is installed.
    public static func navigate(to section: SettingsSection, anchor: String?) -> Bool {
        // Always update the shared selection model — this is the source of
        // truth the SettingsView binds to, and what makes navigation work even
        // when the window is already open.
        SettingsNavigation.shared.go(section, anchor: anchor)

        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.openSettings(section: section)
            return true
        }
        return false
    }

    /// Bring the Settings window frontmost and raise it. Flips the activation
    /// policy to `.regular`, activates the app, then `orderFrontRegardless()`
    /// the Settings window. Returns `(opened, raised)` — `raised` is true when a
    /// Settings window was found and ordered front.
    @discardableResult
    public static func focusSettings(openIfNeeded: Bool) -> (windowFound: Bool, activated: Bool) {
        // Ensure the window exists if requested and none is open yet.
        if openIfNeeded {
            let alreadyOpen = NSApp.windows.contains { $0.isVisible && isSettingsWindow($0) }
            if !alreadyOpen, let delegate = NSApp.delegate as? AppDelegate {
                delegate.openSettings(section: nil)
            }
        }

        // Accessory (LSUIElement) windows hide when the app deactivates; flip to
        // .regular so the window can come fully frontmost and stay visible to a
        // following screen_capture.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        guard let window = NSApp.windows.first(where: { isSettingsWindow($0) }) else {
            return (windowFound: false, activated: true)
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        // orderFrontRegardless brings the window forward even if the app is not
        // (yet) the active app — the key difference for an accessory app whose
        // window otherwise hides on deactivation.
        window.orderFrontRegardless()
        return (windowFound: true, activated: true)
    }
}

// MARK: - BridgeAutomationModule (tool registration)

public enum BridgeAutomationModule {

    /// Own module family ("automation") so the two Settings-driver tools are
    /// counted distinctly from the OS-info `system` family (whose tool count is
    /// pinned by SystemModuleTests / EndToEndTests).
    public static let moduleName = "automation"

    private static func unwrap(_ arguments: Value) -> [String: Value] {
        if case .object(let a) = arguments { return a }
        return [:]
    }

    private static func stringParam(_ p: [String: Value], _ k: String) -> String? {
        if case .string(let s) = p[k] { return s }
        return nil
    }

    private static func boolParam(_ p: [String: Value], _ k: String, default fb: Bool) -> Bool {
        if case .bool(let b) = p[k] { return b }
        return fb
    }

    public static func register(on router: ToolRouter) async {

        // ── bridge_settings_navigate (open) ──────────────────────────────
        await router.register(ToolRegistration(
            name: "bridge_settings_navigate",
            module: moduleName,
            tier: .open,
            description: "Deterministically navigate The Bridge's in-app Settings window to a named section (drives SettingsNavigation.shared.go). Opens the window if closed and deep-links to the section. Prefer this over synthetic AX presses on the unlabeled sidebar nav buttons. Pair with bridge_focus_settings + screen_capture to read the resulting view.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "section": .object([
                        "type": .string("string"),
                        "description": .string("Settings section to navigate to. One of: \(BridgeSettingsAutomation.sectionRawValues.joined(separator: ", ")). Case-insensitive; the enum case name (e.g. 'standingOrders') is also accepted."),
                        "enum": .array(BridgeSettingsAutomation.sectionRawValues.map { .string($0) })
                    ]),
                    "anchor": .object([
                        "type": .string("string"),
                        "description": .string("Optional sub-section anchor (e.g. a credential row slug) passed through to the section.")
                    ])
                ]),
                "required": .array([.string("section")])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                guard let rawSection = stringParam(params, "section"), !rawSection.isEmpty else {
                    return .object([
                        "error": .string("section is required (string)"),
                        "code":  .string("invalid_input"),
                        "validSections": .array(await BridgeSettingsAutomation.sectionRawValues.map { .string($0) })
                    ])
                }
                let anchor = stringParam(params, "anchor")

                let resolved = await BridgeSettingsAutomation.resolveSection(rawSection)
                guard let section = resolved else {
                    return .object([
                        "error": .string("Unknown section '\(rawSection)'."),
                        "code":  .string("invalid_input"),
                        "validSections": .array(await BridgeSettingsAutomation.sectionRawValues.map { .string($0) })
                    ])
                }

                let windowDriven = await BridgeSettingsAutomation.navigate(to: section, anchor: anchor)
                var result: [String: Value] = [
                    "success": .bool(true),
                    "section": .string(section.rawValue),
                    "windowOpened": .bool(windowDriven)
                ]
                if let anchor { result["anchor"] = .string(anchor) }
                if !windowDriven {
                    // No AppDelegate (headless/test) — selection model still set.
                    result["note"] = .string("Selection model updated; no app window host present to open.")
                }
                return .object(result)
            }
        ))

        // ── bridge_focus_settings (notify) ───────────────────────────────
        await router.register(ToolRegistration(
            name: "bridge_focus_settings",
            module: moduleName,
            tier: .notify,
            description: "Bring The Bridge's Settings window frontmost and raise it. The app is LSUIElement (menu-bar accessory), so the Settings window hides when the app deactivates — which breaks screen_capture of it. This flips the activation policy to .regular, activates the app, and orders the Settings window front. Call before screen_capture to reliably see Settings.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "openIfNeeded": .object([
                        "type": .string("boolean"),
                        "description": .string("Open the Settings window first if none is currently open (default: true).")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                let openIfNeeded = boolParam(params, "openIfNeeded", default: true)
                let outcome = await BridgeSettingsAutomation.focusSettings(openIfNeeded: openIfNeeded)
                return .object([
                    "success":     .bool(true),
                    "windowFound": .bool(outcome.windowFound),
                    "activated":   .bool(outcome.activated),
                    "note": .string(outcome.windowFound
                        ? "Settings window raised frontmost; activation policy is .regular."
                        : "App activated but no Settings window found — call bridge_settings_navigate first (or pass openIfNeeded=true with an app host present).")
                ])
            }
        ))
    }
}
