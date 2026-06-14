// CommandsEditorView.swift — Settings → Commands master-detail editor.
// PKT-6 UI v3.5 · Commands redesign (bundle-2). Mirrors the locked mockup
// (design/.../ui_kits/the-bridge/Commands.jsx + commands.css): an alphabetical
// master list (A→Z) on the left, a command editor on the right (name, command
// markdown, color/icon picker, favorite-slot grid, Command-Bridge tray preview).
//
// Restructure is VIEW-ONLY. Every binding is preserved verbatim: CommandStore
// CRUD (create / update / delete / setKeySlot), the icon/color picker sheet,
// favorite-slot assignment + eviction, and clipboard-copy of the markdown body.
// The `commands` array + `selectedSlug` are owned by CommandsSection and passed
// as bindings so the hero stat tiles stay live with this pane's edits.

import SwiftUI
import AppKit

public struct CommandsEditorView: View {
    @Binding private var commands: [CommandStore.Command]
    @Binding private var selectedSlug: String?

    // Adaptive key-cap / tray sheen: the raised "keycap" + tray surfaces used
    // raw Color.white/black literals that wash out on titanium. We compute the
    // sheen + drop-shadow per color-scheme so both themes read correctly (DARK
    // keeps the original values; LIGHT uses a subtler neutral lift).
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    @State private var loadError: String? = nil
    @State private var saveMessage: String? = nil
    @State private var searchQuery: String = ""
    // PKT-879: icon picker sheet state
    @State private var iconPickerPresented: Bool = false

    public init(
        commands: Binding<[CommandStore.Command]>,
        selectedSlug: Binding<String?>
    ) {
        self._commands = commands
        self._selectedSlug = selectedSlug
    }

    public var body: some View {
        BridgeGlassCard(padding: 0) {
            HStack(spacing: 0) {
                masterColumn
                    .frame(width: 236)
                Rectangle().fill(BridgeTokens.hairline).frame(width: 0.5)
                detailColumn
                    .frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
        // PKT-879: icon picker sheet
        .sheet(isPresented: $iconPickerPresented) {
            if let cmd = currentCommand {
                IconPickerSheet(
                    isPresented: $iconPickerPresented,
                    currentIcon: cmd.icon,
                    currentColor: cmd.color,
                    onPick: { newIcon, newColor in
                        applyIconAndColor(slug: cmd.slug, icon: newIcon, color: newColor)
                    }
                )
            }
        }
    }

    // MARK: - Master column (alphabetical list)

    private var masterColumn: some View {
        VStack(spacing: 0) {
            // search + new
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg5)
                    TextField("Search commands", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg2)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
                .bridgeBevel(BridgeTokens.bevelInset, radius: 8)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))

                Button {
                    createNew()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(AddCommandButtonStyle())
                .help("New command")
            }
            .padding(.horizontal, 12)
            .padding(.top, 13)
            .padding(.bottom, 9)

            // list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sortedCommands, id: \.slug) { c in
                        commandRow(c)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
            HStack {
                Text("\(commands.count) commands · \(favoriteCount) favorites")
                    .font(BridgeTokens.Typeface.micro)
                    .monospacedDigit()
                    .foregroundStyle(BridgeTokens.fg4)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(maxHeight: .infinity)
    }

    private func commandRow(_ c: CommandStore.Command) -> some View {
        let selected = selectedSlug == c.slug
        return Button {
            selectedSlug = c.slug
            saveMessage = nil
        } label: {
            HStack(spacing: 10) {
                iconBubble(c.icon, color: c.color, diameter: 26, glyph: 14)
                Text(c.name)
                    .font(BridgeTokens.Typeface.base.weight(.medium))
                    .foregroundStyle(BridgeTokens.fg1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let slot = c.keySlot {
                    Text(String(slot))
                        .font(BridgeTokens.Typeface.micro.weight(.semibold).monospacedDigit())
                        .foregroundStyle(BridgeTokens.fg3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(BridgeTokens.chipFill, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(rowBackground(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// `.cmdp-item` background. Selected = the canonical raised NEUTRAL glass
    /// thumb (glass-control fill + control bevel + hairline edge), matching the
    /// design (accent stays reserved for primary actions, per the W2 idiom).
    @ViewBuilder
    private func rowBackground(selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if selected {
            shape
                .fill(BridgeTokens.glassControl)
                .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .bridgeBevel(BridgeTokens.bevelControl, radius: 8)
        } else {
            shape.fill(Color.clear)
        }
    }

    // MARK: - Detail column (editor)

    @ViewBuilder private var detailColumn: some View {
        if let cmd = currentCommand {
            ScrollView {
                VStack(spacing: 13) {
                    editorHeader(cmd)
                    favoriteSlotCard(cmd)
                    bodyCard(cmd)
                    trayPreviewCard
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        } else {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editorHeader(_ c: CommandStore.Command) -> some View {
        HStack(spacing: 14) {
            // PKT-879: the header icon is the picker entry point.
            Button {
                iconPickerPresented = true
            } label: {
                iconBubble(c.icon, color: c.color, diameter: 46, glyph: 23)
            }
            .buttonStyle(.plain)
            .help("Change icon")
            .accessibilityLabel("Change icon")

            // Name — inline editable, no favorite star (the assigned number
            // IS the favorite indicator; it lives in the slot grid below).
            TextField("Command name", text: Binding(
                get: { c.name },
                set: { updateName(slug: c.slug, name: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(BridgeTokens.fg1)

            Spacer(minLength: 8)

            HStack(spacing: 3) {
                headerAction("doc.on.clipboard", help: "Copy markdown to clipboard") { copyBody(c) }
                headerAction("doc.on.doc", help: "Duplicate") { duplicate(c) }
                headerAction("trash", help: "Delete", danger: true) { delete(c) }
            }
        }
    }

    private func headerAction(
        _ systemImage: String,
        help: String,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(danger ? BridgeTokens.badText : BridgeTokens.fg3)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func favoriteSlotCard(_ c: CommandStore.Command) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                // Reset lives in the top-right corner (no caption needed).
                HStack(spacing: 6) {
                    BridgeCardLabel("Favorite slot")
                    Spacer()
                    // Change icon — moved here from the removed Appearance card;
                    // sits immediately to the LEFT of Reset (operator feedback).
                    Button {
                        iconPickerPresented = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 12))
                            .foregroundStyle(BridgeTokens.fg3)
                            .frame(width: 26, height: 26)
                            .background(BridgeTokens.hoverFill, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Change icon")
                    .accessibilityLabel("Change icon")
                    Button {
                        setSlot(slug: c.slug, slot: nil)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .foregroundStyle(BridgeTokens.fg3)
                            .frame(width: 26, height: 26)
                            .background(BridgeTokens.hoverFill, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(c.keySlot == nil)
                    .opacity(c.keySlot == nil ? 0.4 : 1.0)
                    .help("Clear favorite slot")
                }
                // Slots 1…9, 0 — evenly distributed.
                HStack(spacing: 7) {
                    ForEach(slotKeys, id: \.self) { slot in
                        slotButton(slot: slot, cmd: c)
                    }
                }
            }
        }
    }

    private var slotKeys: [Int] { [1, 2, 3, 4, 5, 6, 7, 8, 9, 0] }

    // Favorite-slot keys (`.cmdp-slot`): square keyboard-style caps that fill the
    // row. At rest they are recessed wells (well fill + inset bevel + hairline);
    // a taken slot drops to a dashed ghost; the assigned slot lights up as a
    // raised neutral glass thumb ringed in `accentBorder` (the design's `.on`).
    private func slotButton(slot: Int, cmd: CommandStore.Command) -> some View {
        let isMine = cmd.keySlot == slot
        let isTaken = commands.contains { $0.slug != cmd.slug && $0.keySlot == slot }
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            setSlot(slug: cmd.slug, slot: slot)
        } label: {
            Text(String(slot))
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(isMine ? BridgeTokens.fg1
                                 : (isTaken ? BridgeTokens.fg5 : BridgeTokens.fg2))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(slotKeyBackground(isMine: isMine, isTaken: isTaken, shape: shape))
                .overlay(
                    shape.strokeBorder(
                        isMine ? BridgeTokens.accentBorder
                               : (isTaken ? BridgeTokens.hairlineStrong : BridgeTokens.hairline),
                        style: StrokeStyle(lineWidth: isMine ? 1 : 0.5,
                                           dash: isTaken ? [3, 2.5] : [])
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isTaken && !isMine)
        .help(isTaken ? "Slot \(slot) — taken by another command" : "Assign slot \(slot)")
    }

    /// Slot-key surface. Assigned = raised neutral glass thumb (control fill +
    /// bevel); taken = transparent ghost; resting = recessed inset well. All
    /// adaptive via tokens — no raw white/black washes that vanish on titanium.
    @ViewBuilder
    private func slotKeyBackground(
        isMine: Bool,
        isTaken: Bool,
        shape: RoundedRectangle
    ) -> some View {
        if isMine {
            shape
                .fill(BridgeTokens.glassControl)
                .bridgeBevel(BridgeTokens.bevelControl, radius: 10)
        } else if isTaken {
            shape.fill(Color.clear)
        } else {
            shape
                .fill(BridgeTokens.wellFill)
                .bridgeBevel(BridgeTokens.bevelInset, radius: 10)
        }
    }

    private func bodyCard(_ c: CommandStore.Command) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("Command")
                    Spacer()
                    Text("Copied to clipboard as plain-text markdown")
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg5)
                }
                TextEditor(text: Binding(
                    get: { c.body },
                    set: { updateBody(slug: c.slug, body: $0) }
                ))
                .font(BridgeTokens.Typeface.mono)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 150)
                .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: 8))
                .bridgeBevel(BridgeTokens.bevelInset, radius: 8)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .accessibilityLabel("Command markdown editor")
                if let msg = saveMessage {
                    Text(msg)
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg3)
                }
            }
        }
    }

    // MARK: - Command-Bridge tray preview

    /// Live preview of the Command-Bridge tray: up to 10 bubbles for FAVORED
    /// slots, ordered 1…9 then 0, expanding toward 10 as more are favored.
    /// No descriptive text — the tray itself is the explainer.
    private var trayPreviewCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("In the Command Bridge")
                if favoredCommands.isEmpty {
                    HStack {
                        Spacer()
                        Text("No favorites yet — assign a slot above to place a bubble here.")
                            .font(.system(size: 12))
                            .foregroundStyle(BridgeTokens.fg4)
                        Spacer()
                    }
                    .padding(.vertical, 18)
                } else {
                    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                    HStack(alignment: .top, spacing: 12) {
                        Spacer(minLength: 0)
                        ForEach(favoredCommands, id: \.slug) { c in
                            VStack(spacing: 6) {
                                trayBubble(c)
                                Text(String(c.keySlot ?? 0))
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(BridgeTokens.fg4)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .background(
                        shape.fill(BridgeTokens.wellFillDeep)
                            .bridgeBevel(BridgeTokens.bevelInset, radius: 14)
                    )
                    .overlay(shape.strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
                }
            }
        }
    }

    /// Tray bubble — ALL favorites render at full opacity (the real Command
    /// Bridge shows every favorite, not just the selected one). The currently
    /// EDITED command is marked with the design's double-ring (a canvas-colored
    /// gap then an `accent-strong` halo) rather than by dimming the rest (fix U8).
    private func trayBubble(_ c: CommandStore.Command) -> some View {
        let isSelected = c.slug == selectedSlug
        return iconBubble(c.icon, color: c.color, diameter: 40, glyph: 21)
            .overlay(
                Circle().strokeBorder(BridgeTokens.bgCanvas,
                                      lineWidth: isSelected ? 2 : 0)
            )
            .overlay(
                Circle()
                    .inset(by: -2)
                    .strokeBorder(isSelected ? BridgeTokens.accentStrong : Color.clear,
                                  lineWidth: 1.5)
            )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 36))
                .foregroundStyle(BridgeTokens.fg4)
            Text("No command selected")
                .font(BridgeTokens.Typeface.name)
                .foregroundStyle(BridgeTokens.fg2)
            Text("Pick one from the list, or create a new command with the + button.")
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg4)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - Icon bubble

    /// `.cmdp-orb` — a glass "orb": a top-left radial sheen over the neutral
    /// control surface, ringed with a hairline-strong edge and lifted by the
    /// control bevel. The sheen brightens on titanium (light) to read on the
    /// pale canvas, matching the design's `[data-theme="titanium"] .cmdp-orb`.
    @ViewBuilder
    private func iconBubble(
        _ icon: CommandStore.Icon,
        color: CommandStore.NotionColor?,
        diameter: CGFloat,
        glyph: CGFloat
    ) -> some View {
        ZStack {
            Circle().fill(BridgeTokens.glassControl)
            Circle().fill(orbSheen)
            Circle().strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5)
            switch icon {
            case .emoji(let s):
                Text(s).font(.system(size: glyph))
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: glyph * 0.7, weight: .medium))
                    .foregroundStyle(color.flatMap { NotionPalette.color(named: $0.rawValue) } ?? BridgeTokens.fg1)
            }
        }
        .frame(width: diameter, height: diameter)
        .bridgeBevel(BridgeTokens.bevelControl, radius: diameter / 2)
    }

    /// Top-left specular sheen for the orb (`radial-gradient(… at 30% 18%)`).
    private var orbSheen: RadialGradient {
        RadialGradient(
            colors: isDark
                ? [Color.white.opacity(0.18), Color.white.opacity(0.04), .clear]
                : [Color.white.opacity(0.85), Color.white.opacity(0.25), .clear],
            center: UnitPoint(x: 0.30, y: 0.18),
            startRadius: 0,
            endRadius: diameterHint
        )
    }

    /// Sheen radius hint — the orb circles are small (26–46px); a fixed ~26pt
    /// end-radius keeps the highlight in the upper-left quadrant at every size.
    private let diameterHint: CGFloat = 26

    // MARK: - Computed

    /// Alphabetical (A→Z by name), filtered by the search field.
    private var sortedCommands: [CommandStore.Command] {
        let base = commands.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.name.lowercased().contains(q) }
    }

    /// Favored commands for the tray — ordered by slot 1…9 then 0, capped at 10.
    private var favoredCommands: [CommandStore.Command] {
        commands
            .filter { $0.keySlot != nil }
            .sorted { slotOrder($0.keySlot) < slotOrder($1.keySlot) }
            .prefix(10)
            .map { $0 }
    }

    /// Slot 0 sorts last (treated as 10), 1…9 in natural order.
    private func slotOrder(_ slot: Int?) -> Int {
        guard let s = slot else { return Int.max }
        return s == 0 ? 10 : s
    }

    private var currentCommand: CommandStore.Command? {
        commands.first(where: { $0.slug == selectedSlug })
    }

    private var favoriteCount: Int { commands.filter { $0.keySlot != nil }.count }

    // MARK: - Mutations (bindings preserved verbatim)

    private func load() async {
        do {
            try CommandStore.shared.seedIfEmpty()
            let list = try CommandStore.shared.list()
            await MainActor.run {
                self.commands = list
                if self.selectedSlug == nil || !list.contains(where: { $0.slug == self.selectedSlug }) {
                    self.selectedSlug = self.firstAlphabetical(list)?.slug
                }
                self.loadError = nil
            }
        } catch {
            await MainActor.run { self.loadError = error.localizedDescription }
        }
    }

    private func firstAlphabetical(_ list: [CommandStore.Command]) -> CommandStore.Command? {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.first
    }

    private func createNew() {
        let baseName = "New command"
        var name = baseName
        var i = 1
        while commands.contains(where: { $0.name == name }) {
            i += 1
            name = "\(baseName) \(i)"
        }
        do {
            let c = try CommandStore.shared.create(
                name: name,
                icon: .emoji("✨"),
                body: "## \(name)\n\n"
            )
            commands = (try? CommandStore.shared.list()) ?? commands
            selectedSlug = c.slug
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private func updateName(slug: String, name: String) {
        guard var c = commands.first(where: { $0.slug == slug }) else { return }
        c.name = name
        applyUpdate(c)
    }

    private func updateBody(slug: String, body: String) {
        guard var c = commands.first(where: { $0.slug == slug }) else { return }
        c.body = body
        applyUpdate(c)
    }

    /// PKT-879: atomic icon + color update from the icon picker sheet.
    /// Color is only relevant for symbol icons; the picker passes `nil`
    /// for emoji selections.
    private func applyIconAndColor(
        slug: String,
        icon: CommandStore.Icon,
        color: CommandStore.NotionColor?
    ) {
        guard var c = commands.first(where: { $0.slug == slug }) else { return }
        c.icon = icon
        c.color = color
        applyUpdate(c)
    }

    private func setSlot(slug: String, slot: Int?) {
        do {
            try CommandStore.shared.setKeySlot(slug: slug, slot: slot)
            commands = (try? CommandStore.shared.list()) ?? commands
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private func applyUpdate(_ c: CommandStore.Command) {
        do {
            _ = try CommandStore.shared.update(c)
            commands = (try? CommandStore.shared.list()) ?? commands
            saveMessage = "Saved"
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    /// Clipboard-copy of the command's markdown body — the literal payload
    /// the Command Bridge popup copies. Binding preserved + surfaced here.
    private func copyBody(_ c: CommandStore.Command) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(c.body, forType: .string)
        saveMessage = "Copied to clipboard"
    }

    private func duplicate(_ c: CommandStore.Command) {
        var name = "\(c.name) copy"
        var i = 1
        while commands.contains(where: { $0.name == name }) {
            i += 1; name = "\(c.name) copy \(i)"
        }
        do {
            let new = try CommandStore.shared.create(
                name: name, icon: c.icon, color: c.color, body: c.body
            )
            commands = (try? CommandStore.shared.list()) ?? commands
            selectedSlug = new.slug
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private func delete(_ c: CommandStore.Command) {
        do {
            try CommandStore.shared.delete(slug: c.slug)
            let list = try CommandStore.shared.list()
            self.commands = list
            self.selectedSlug = firstAlphabetical(list)?.slug
        } catch {
            saveMessage = error.localizedDescription
        }
    }
}

// MARK: - Add-command button style

/// The "+" new-command button: GREEN (signal-ok) at rest, neutral GRAY while
/// pressed. Keyed on `configuration.isPressed` so the fill/icon/border swap to
/// a muted gray on press, then snap back to green on release — adaptive in both
/// themes (all tokens via BridgeTokens, no hardcoded white/black).
private struct AddCommandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let icon = pressed ? BridgeTokens.fg4 : BridgeTokens.ok
        let fill = pressed ? BridgeTokens.wellFill : BridgeTokens.ok.opacity(0.28)
        let border = pressed ? BridgeTokens.hairline : BridgeTokens.ok.opacity(0.45)
        return configuration.label
            .foregroundStyle(icon)
            .frame(width: 30, height: 30)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}
