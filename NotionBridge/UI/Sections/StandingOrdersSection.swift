// StandingOrdersSection.swift — Settings → Commands (the command-palette manager).
// PKT-9 UI v3.5 · v3.7.6 redesign · Settings-Redesign PKT-orders · IA change 2026-06-12:
//
// This file hosts the `OrdersSection` page — the focused **Commands** manager.
// The v4 IA split the merged "Orders & Commands" page apart: the standing-orders
// doctrine moved OUT to Connection's "Agent handshake" (where it is store-backed
// and handed to clients at connect), and this page is now COMMANDS ONLY — the
// command library you fire from the Command Bridge (⌃⌘B). The old Orders|Commands
// tab strip, the doctrine sub-area body, and all of its draft/snapshot/routing
// state are gone.
//
// The enum case + rawValue keep the legacy `.orders` / "Standing Orders" id so
// existing MCP `bridge_settings_navigate` deep-links still resolve — only the UI
// label (sidebar + title bar) is "Commands". The on-disk standing-orders store,
// the standing_orders_* MCP tools, and the doctrine editor all still exist; the
// editable global doctrine now lives in ConnectionsSection.

import SwiftUI
import AppKit

// MARK: - Commands page (bespoke single-surface — the command-palette manager)

/// The **Commands** Settings page: a shared section header, a slim meta row
/// (command/favorite counts + the labeled Command Bridge master switch), and the
/// command master–detail filling the remaining height. Mirrors the design's
/// `page-commands.jsx` slim-meta-row anatomy (no doctrine — that moved to
/// Connection).
public struct OrdersSection: View {
    /// Deep-link anchor (e.g. `commands`) — retained for back-compat with the old
    /// merged page's tab anchors; this page is commands-only so it has no effect
    /// on which sub-surface shows, but the parameter stays so existing nav calls
    /// (`SettingsNavigation.shared.go(.orders, anchor: "commands")`) compile.
    let anchor: String?

    // ── Commands page persistent state ──────────────────────────────────────
    @AppStorage(BridgeDefaults.commandsPaletteEnabled) private var paletteEnabled: Bool = true
    @State private var commands: [CommandStore.Command] = []
    @State private var selectedSlug: String? = nil

    public init(anchor: String?) {
        self.anchor = anchor
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, BridgeTokens.Space.cardGap)
            metaBar
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, 12)
                .padding(.bottom, 12)

            Divider().background(BridgeTokens.hairlineFaint)

            CommandsSection(
                commands: $commands,
                selectedSlug: $selectedSlug
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
    }

    // MARK: Header (shared section header — commands-only copy)

    private var header: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .orders)
        return BridgeSettingsSectionHeader(
            title: "Commands",
            subtitle: "Your command library — fire any command from the Command Bridge (⌃⌘B).",
            systemImage: spec.systemImage,
            tint: spec.tint
        )
    }

    // MARK: Slim meta row (counts + Command Bridge master switch)

    /// The slim meta row (design `page-commands.jsx` `.cmdp-meta`): live
    /// command/favorite counts + the labeled Command Bridge master switch (was
    /// the unlabeled hero toggle). The ⌃⌘B recorder lives in the slim shortcut
    /// row inside `CommandsSection`.
    private var metaBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                metaStat(value: "\(commands.count)", label: "commands", color: BridgeTokens.accentLink)
                metaStat(value: "\(favoriteCount)", label: "favorites", color: BridgeTokens.gold)
                commandBridgeSwitch
            }
        }
    }

    private func metaStat(value: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(BridgeTokens.Typeface.body.monospaced())
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(BridgeTokens.Typeface.cap)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    /// The Command Bridge master switch — a LABELED control (the hero toggle had
    /// only a tooltip). Destructive-global affordance deserves a visible label +
    /// a11y label.
    private var commandBridgeSwitch: some View {
        HStack(spacing: 8) {
            Text("Command Bridge")
                .font(BridgeTokens.Typeface.meta.weight(.medium))
                .foregroundStyle(BridgeTokens.fg2)
            Toggle("", isOn: $paletteEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: paletteEnabled) { _, newValue in
                    (NSApp.delegate as? AppDelegate)?.setCommandsPaletteEnabled(newValue)
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .help("Enable the global Command Bridge popup hot-key.")
        .accessibilityLabel("Command Bridge global hot-key")
        .accessibilityValue(paletteEnabled ? "on" : "off")
    }

    private var favoriteCount: Int { commands.filter { $0.keySlot != nil }.count }
}
