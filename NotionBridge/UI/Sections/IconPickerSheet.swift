// IconPickerSheet.swift — PKT-879 (v3.6.4) Commands icon picker.
//
// Sheet presented from CommandsEditorView when the user clicks the icon
// pill. Three surfaces, per design/command-settings.html:
//   • Emoji tab — grid of curated emoji with a search field
//   • Symbol tab — curated ~200 SF Symbols rendered via
//     `NSImage(systemSymbolName:)` (Locked Decision Q1 — no SPM dep)
//   • Notion color swatches — only meaningful for symbol icons; the row
//     stays visible but the swatch interactions disable when the user is
//     on the emoji tab (mirrors the locked HTML: "Color applies to
//     symbols, not emoji")
//
// Selection is immediate on tap (Locked Decision Q2) — the sheet
// dismisses and the caller persists through CommandStore.

import SwiftUI
import AppKit

/// Public API for the icon picker.
///
/// The caller binds `isPresented` and supplies an `onPick` closure that
/// receives the new `(Icon, NotionColor?)` pair. The picker does not
/// touch CommandStore directly — that's the host's responsibility, so
/// the sheet remains testable as a pure UI primitive.
public struct IconPickerSheet: View {
    @Binding public var isPresented: Bool
    public let currentIcon: CommandStore.Icon
    public let currentColor: CommandStore.NotionColor?
    public let onPick: (CommandStore.Icon, CommandStore.NotionColor?) -> Void

    @State private var tab: PickerTab = .emoji
    @State private var query: String = ""
    @State private var selectedColor: CommandStore.NotionColor

    public init(
        isPresented: Binding<Bool>,
        currentIcon: CommandStore.Icon,
        currentColor: CommandStore.NotionColor?,
        onPick: @escaping (CommandStore.Icon, CommandStore.NotionColor?) -> Void
    ) {
        self._isPresented = isPresented
        self.currentIcon = currentIcon
        self.currentColor = currentColor
        self.onPick = onPick
        _selectedColor = State(initialValue: currentColor ?? .blue)
        // Land on the tab that matches the current icon.
        switch currentIcon {
        case .emoji:  _tab = State(initialValue: .emoji)
        case .symbol: _tab = State(initialValue: .symbol)
        }
    }

    public enum PickerTab: String, CaseIterable {
        case emoji, symbol
        public var label: String { rawValue.capitalized }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.10))
            tabBar
            swatchRow
            searchField
            Divider().background(Color.white.opacity(0.10))
            grid
                .frame(minHeight: 240, maxHeight: 320)
            Divider().background(Color.white.opacity(0.10))
            footer
        }
        .frame(width: 420, height: 480)
        .background(
            ZStack {
                Color(red: 0.09, green: 0.09, blue: 0.105)
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.white.opacity(0.01)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Choose an icon")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button("Done") {
                isPresented = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PickerTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.label)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tab == t ? Color.white.opacity(0.10) : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(tab == t ? Color.white.opacity(0.18) : Color.clear,
                                                      lineWidth: 0.5)
                                )
                        )
                        .foregroundStyle(tab == t ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.18))
    }

    // MARK: - Color swatch row

    private var swatchRow: some View {
        HStack(spacing: 6) {
            ForEach(CommandStore.NotionColor.allCases, id: \.self) { c in
                Button {
                    selectedColor = c
                    // If on the symbol tab, immediately apply the color
                    // change to the current symbol (without re-picking).
                    if case .symbol(let n) = currentIcon, tab == .symbol {
                        onPick(.symbol(n), c)
                    }
                } label: {
                    Circle()
                        .fill(NotionPalette.color(named: c.rawValue) ?? .gray)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    selectedColor == c ? Color.white : Color.white.opacity(0.12),
                                    lineWidth: selectedColor == c ? 2 : 0.5
                                )
                        )
                        .opacity(tab == .emoji ? 0.40 : 1.0)
                }
                .buttonStyle(.plain)
                .disabled(tab == .emoji)
            }
            Spacer()
            Text("Color applies to symbols, not emoji")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField(searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var searchPlaceholder: String {
        switch tab {
        case .emoji:  return "Search emoji \u{2014} e.g. spark, lightning"
        case .symbol: return "Search SF Symbols \u{2014} e.g. command, key"
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            switch tab {
            case .emoji:  emojiGrid
            case .symbol: symbolGrid
            }
        }
        .padding(.horizontal, 14)
    }

    private var emojiGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 11),
            spacing: 4
        ) {
            ForEach(filteredEmoji, id: \.self) { e in
                Button {
                    onPick(.emoji(e.emoji), nil) // emoji uses no color
                    isPresented = false
                } label: {
                    Text(e.emoji)
                        .font(.system(size: 18))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isCurrentEmoji(e.emoji) ? Color(red: 0.47, green: 0.63, blue: 0.86).opacity(0.30)
                                                              : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(e.label)
            }
        }
        .padding(.vertical, 6)
    }

    private var symbolGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 11),
            spacing: 4
        ) {
            ForEach(filteredSymbols, id: \.self) { name in
                Button {
                    onPick(.symbol(name), selectedColor)
                    isPresented = false
                } label: {
                    Group {
                        if let image = NSImage(systemSymbolName: name, accessibilityDescription: name) {
                            Image(nsImage: image)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                                .foregroundStyle(NotionPalette.color(named: selectedColor.rawValue) ?? .primary)
                        } else {
                            // Defensive fallback if the symbol is absent on this OS build.
                            Image(systemName: "questionmark.square")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isCurrentSymbol(name) ? Color(red: 0.47, green: 0.63, blue: 0.86).opacity(0.30)
                                                        : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help(name)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(footerHint)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footerHint: String {
        switch tab {
        case .emoji:  return "Tap an emoji to apply \u{2014} the sheet closes immediately"
        case .symbol: return "Tap a symbol to apply with the selected color"
        }
    }

    // MARK: - Filtering

    private var filteredEmoji: [IconPickerSheet.EmojiEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Self.curatedEmoji }
        return Self.curatedEmoji.filter { $0.label.lowercased().contains(q) }
    }

    private var filteredSymbols: [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Self.curatedSymbols }
        return Self.curatedSymbols.filter { $0.lowercased().contains(q) }
    }

    private func isCurrentEmoji(_ e: String) -> Bool {
        if case .emoji(let s) = currentIcon { return s == e }
        return false
    }
    private func isCurrentSymbol(_ name: String) -> Bool {
        if case .symbol(let n) = currentIcon { return n == name }
        return false
    }

    // MARK: - Curated data

    public typealias EmojiEntry = IconPickerCatalog.EmojiEntry

    /// Curated emoji palette — proxied for backward compatibility with
    /// existing call sites. The canonical list lives on
    /// `IconPickerCatalog` (non-isolated, accessible from tests).
    public static var curatedEmoji: [IconPickerCatalog.EmojiEntry] {
        IconPickerCatalog.curatedEmoji
    }

    /// Curated SF Symbols — proxied to `IconPickerCatalog`.
    public static var curatedSymbols: [String] {
        IconPickerCatalog.curatedSymbols
    }
}

/// Non-View, non-isolated catalog for the picker. Hoisted out of
/// `IconPickerSheet` (which is `@MainActor` via `View` conformance) so
/// tests can read the lists without main-actor hopping.
public enum IconPickerCatalog {
    public struct EmojiEntry: Hashable, Sendable {
        public let emoji: String
        public let label: String
        public init(emoji: String, label: String) {
            self.emoji = emoji
            self.label = label
        }
    }

    public static let curatedEmoji: [EmojiEntry] = [
        // ideas / talk
        .init(emoji: "\u{1F4A1}", label: "lightbulb"),
        .init(emoji: "\u{1F4DD}", label: "memo"),
        .init(emoji: "\u{1F4AC}", label: "speech bubble"),
        .init(emoji: "\u{1F5E3}\u{FE0F}", label: "speaking"),
        .init(emoji: "\u{1F4DE}", label: "phone"),
        // mail / comms
        .init(emoji: "\u{2709}\u{FE0F}", label: "envelope mail"),
        .init(emoji: "\u{1F4E8}", label: "incoming envelope"),
        .init(emoji: "\u{1F4E4}", label: "outbox"),
        .init(emoji: "\u{1F4E5}", label: "inbox"),
        .init(emoji: "\u{1F4CB}", label: "clipboard"),
        .init(emoji: "\u{1F4CC}", label: "pin"),
        // magic / energy
        .init(emoji: "\u{1FA84}", label: "magic wand"),
        .init(emoji: "\u{26A1}", label: "lightning bolt energy execute"),
        .init(emoji: "\u{1F525}", label: "fire hot urgent"),
        .init(emoji: "\u{2B50}", label: "star favorite"),
        .init(emoji: "\u{2728}", label: "sparkles new shiny"),
        // direction / progress
        .init(emoji: "\u{1F680}", label: "rocket launch ship"),
        .init(emoji: "\u{1F3AF}", label: "target goal aim"),
        .init(emoji: "\u{1F4C8}", label: "chart up trend"),
        .init(emoji: "\u{1F4CA}", label: "bar chart report"),
        .init(emoji: "\u{1F50D}", label: "magnifying glass search"),
        .init(emoji: "\u{1F9ED}", label: "compass direction"),
        // process / loop
        .init(emoji: "\u{1F501}", label: "loop reflow repeat"),
        .init(emoji: "\u{2705}", label: "checkmark done complete"),
        .init(emoji: "\u{2699}\u{FE0F}", label: "gear settings orchestration"),
        .init(emoji: "\u{1F91D}", label: "handshake handoff agent"),
        // tools / coding
        .init(emoji: "\u{1F527}", label: "wrench tool"),
        .init(emoji: "\u{1F528}", label: "hammer build"),
        .init(emoji: "\u{1F4BB}", label: "laptop code"),
        .init(emoji: "\u{1F4DA}", label: "books documentation"),
        .init(emoji: "\u{1F4D6}", label: "open book read"),
        .init(emoji: "\u{1F4F0}", label: "newspaper article"),
        // people / agents
        .init(emoji: "\u{1F464}", label: "person silhouette"),
        .init(emoji: "\u{1F465}", label: "people group"),
        .init(emoji: "\u{1F916}", label: "robot agent"),
        .init(emoji: "\u{1F9E0}", label: "brain memory"),
        // signals / flags
        .init(emoji: "\u{1F6A9}", label: "flag triage"),
        .init(emoji: "\u{26A0}\u{FE0F}", label: "warning"),
        .init(emoji: "\u{1F4A2}", label: "anger pushback"),
        .init(emoji: "\u{1F4E2}", label: "loud speaker announce"),
        .init(emoji: "\u{1F4E3}", label: "megaphone shout"),
        // misc
        .init(emoji: "\u{1F511}", label: "key access secret"),
        .init(emoji: "\u{1F510}", label: "closed lock with key secure"),
        .init(emoji: "\u{1F4A4}", label: "sleep idle"),
        .init(emoji: "\u{1F389}", label: "party celebration ship"),
        .init(emoji: "\u{1F4E6}", label: "package release"),
        .init(emoji: "\u{1F4F1}", label: "phone mobile"),
    ]

    /// Curated SF Symbol set (Locked Decision Q1 — ~200, used via
    /// `NSImage(systemSymbolName:)`). The order favours
    /// commands / agents / files / tools / status so the picker reads
    /// like a designed palette rather than a dump of every symbol.
    public static let curatedSymbols: [String] = [
        // command core
        "command", "command.circle", "command.square",
        "keyboard", "keyboard.macwindow", "option", "shift", "control",
        "return", "delete.left", "escape",
        // agent / star / sparkle
        "sparkle", "sparkles", "wand.and.stars", "wand.and.rays",
        "star", "star.fill", "star.circle", "rosette",
        // run / play / pause
        "play.fill", "play.circle.fill", "pause.fill", "stop.fill",
        "forward.fill", "backward.fill",
        "bolt.fill", "bolt.circle.fill", "bolt.badge.automatic.fill",
        // arrow / loop / reflow
        "arrow.clockwise", "arrow.counterclockwise",
        "arrow.triangle.2.circlepath", "arrow.uturn.left", "arrow.uturn.right",
        "arrow.up.right", "arrow.down.left", "arrow.up.forward.app",
        "shuffle", "repeat", "repeat.1",
        // checks / status
        "checkmark", "checkmark.circle", "checkmark.circle.fill",
        "checkmark.seal", "checkmark.shield", "xmark", "xmark.circle.fill",
        "exclamationmark.triangle", "exclamationmark.octagon",
        "questionmark.circle", "info.circle",
        // people / agents
        "person", "person.fill", "person.crop.circle", "person.2",
        "person.2.fill", "person.3.fill",
        "person.wave.2.fill", "person.text.rectangle",
        // chat / message
        "bubble.left", "bubble.right", "bubble.left.and.bubble.right",
        "quote.bubble", "text.bubble", "message", "message.fill",
        "envelope", "envelope.fill", "envelope.open", "tray", "tray.full",
        "paperplane", "paperplane.fill",
        // documents
        "doc", "doc.text", "doc.on.doc", "doc.text.magnifyingglass",
        "doc.richtext", "doc.append", "doc.badge.plus",
        "list.bullet", "list.bullet.indent",
        "list.number", "checklist", "list.dash", "text.alignleft",
        // search / discover
        "magnifyingglass", "magnifyingglass.circle",
        "binoculars", "scope", "viewfinder", "eye",
        // tools / build
        "hammer", "hammer.fill", "wrench.and.screwdriver",
        "wrench.and.screwdriver.fill", "screwdriver",
        "gearshape", "gearshape.fill", "slider.horizontal.3",
        "gauge", "gauge.high", "gauge.low",
        // code / dev
        "chevron.left.forwardslash.chevron.right", "curlybraces",
        "function", "terminal", "scroll", "scroll.fill",
        // network
        "network", "antenna.radiowaves.left.and.right",
        "wifi", "personalhotspot", "globe", "globe.americas.fill",
        "cloud", "cloud.fill", "icloud", "icloud.fill",
        // file / disk
        "folder", "folder.fill", "folder.badge.plus", "tray.and.arrow.up",
        "tray.and.arrow.down", "externaldrive", "externaldrive.fill",
        "internaldrive", "opticaldiscdrive",
        // security
        "lock", "lock.fill", "lock.open", "lock.shield",
        "key", "key.fill", "shield", "shield.fill", "shield.lefthalf.filled",
        // calendar / time / focus
        "calendar", "calendar.badge.plus", "clock", "clock.fill",
        "timer", "stopwatch", "hourglass", "alarm",
        // pin / flag / bookmark
        "pin", "pin.fill", "flag", "flag.fill", "bookmark", "bookmark.fill",
        "tag", "tag.fill", "paperclip",
        // navigation
        "house", "house.fill", "map", "map.fill", "location.fill",
        "location.circle.fill", "compass.drawing", "safari",
        // graph / data
        "chart.bar", "chart.bar.fill", "chart.line.uptrend.xyaxis",
        "chart.pie", "chart.pie.fill", "rectangle.stack",
        "square.grid.2x2", "square.grid.3x3",
        // misc system
        "bell", "bell.fill", "bell.badge.fill", "speaker.wave.2.fill",
        "moon", "moon.fill", "sun.max", "sun.max.fill",
        "lightbulb", "lightbulb.fill",
        // signal flow
        "arrow.left.arrow.right", "arrow.up.arrow.down",
        "rectangle.connected.to.line.below",
        "diamond.fill", "circle.grid.cross", "infinity",
    ]
}
