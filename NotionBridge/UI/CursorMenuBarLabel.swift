// CursorMenuBarLabel.swift — PKT-3.4.2 Wave 2 (Bridge v2.2)
// NotionBridge · UI
//
// The MenuBarExtra label SwiftUI view that renders the Bridge menu bar icon
// plus a compact Cursor agent status pill (`▶⋅N · ✓N · !N`) when any agents
// are active. Observes `CursorAgentRegistry.shared` so the pill updates
// reactively as runs enter/leave running/ready/error states.
//
// Per PKT-774 Scope:
//   “Status surface: `running:N · ready · error` counts in title bar.”
//
// macOS menu bar real estate is precious; we use single-character symbols
// (▶⋅ / ✓ / !) instead of long words and hide zero-count segments. The icon
// remains the always-visible anchor; counts surface only when present.

import SwiftUI
import AppKit

@MainActor
public struct CursorMenuBarLabel: View {

    @ObservedObject private var registry: CursorAgentRegistry
    private let icon: NSImage?

    public init(
        registry: CursorAgentRegistry = .shared,
        icon: NSImage?
    ) {
        self.registry = registry
        self.icon = icon
    }

    public var body: some View {
        let counts = registry.counts
        HStack(spacing: 4) {
            iconView
            if counts.anyActive {
                Text(pillText(counts))
                    .font(.caption2)
                    .monospacedDigit()
                    .accessibilityLabel(accessibilityLabel(counts))
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
        } else {
            // Fallback: text label if icon resource unavailable (preserves prior behavior).
            Text("NB")
                .font(.caption2)
                .fontWeight(.bold)
        }
    }

    /// Compact pill format. Hides zero-count segments to save menu bar space.
    private func pillText(_ c: CursorAgentCounts) -> String {
        var parts: [String] = []
        if c.running > 0 { parts.append("▶⋅\(c.running)") }
        if c.ready > 0 { parts.append("✓\(c.ready)") }
        if c.error > 0 { parts.append("!\(c.error)") }
        return parts.joined(separator: " · ")
    }

    /// VoiceOver-friendly description.
    private func accessibilityLabel(_ c: CursorAgentCounts) -> String {
        var parts: [String] = []
        if c.running > 0 { parts.append("\(c.running) running") }
        if c.ready > 0 { parts.append("\(c.ready) ready") }
        if c.error > 0 { parts.append("\(c.error) error\(c.error == 1 ? "" : "s")") }
        if parts.isEmpty { return "Cursor agents idle" }
        return "Cursor agents: " + parts.joined(separator: ", ")
    }
}
