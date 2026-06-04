// FirstRunCloudAccessModal.swift — WS-G (Bridge Cloud Access · first-run)
// NotionBridge · UI · Sections
//
// The one-time, 3-step guide presented as a `.sheet` from RemoteAccessSection
// the first time cloud access reaches `.online`. Whether it shows at all is
// decided by the pure `FirstRunCloudAccessGate` (unit-tested); this file is
// the thin SwiftUI renderer + the "Got it" dismissal that sets
// `BridgeDefaults.hasSeenCloudAccessFirstRun = true`.
//
// Q2 lock (COA 2026-05-27): shown one time only.

import SwiftUI

public struct FirstRunCloudAccessModal: View {
    /// Called when the user taps "Got it". The parent persists the flag and
    /// dismisses the sheet.
    private let onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void = {}) {
        self.onDismiss = onDismiss
    }

    /// The three guide steps. `static` + `Equatable` so the content is
    /// assertable headlessly without rendering the view.
    public struct Step: Sendable, Equatable, Identifiable {
        public let id: Int
        public let symbol: String
        public let title: String
        public init(id: Int, symbol: String, title: String) {
            self.id = id
            self.symbol = symbol
            self.title = title
        }
    }

    /// `nonisolated` so the (pure value) step content is assertable headlessly
    /// without a MainActor hop — the SF Symbols + copy are the packet contract.
    public nonisolated static let steps: [Step] = [
        Step(id: 1, symbol: "doc.on.clipboard", title: "Copy your MCP URL below."),
        Step(id: 2, symbol: "safari", title: "Open Claude.ai → Settings → Integrations."),
        Step(id: 3, symbol: "checkmark.circle", title: "Paste your URL and connect.")
    ]

    public var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(NotionPalette.blue.opacity(0.20))
                        .frame(width: 52, height: 52)
                    Image(systemName: "cloud")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(NotionPalette.blue)
                }
                Text("Connect Claude to this Mac")
                    .font(.system(size: 18, weight: .semibold))
                Text("Three quick steps to add this Mac as a tool in Claude.ai.")
                    .font(.system(size: 12))
                    .foregroundStyle(BridgeTokens.fg3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.steps) { step in
                    stepRow(step)
                }
            }

            Button(action: onDismiss) {
                Text("Got it")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 360)
    }

    @ViewBuilder
    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(BridgeTokens.chipFill)
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5)
                    )
                Image(systemName: step.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NotionPalette.blue)
            }
            Text(step.title)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
