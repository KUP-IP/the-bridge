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
                        .foregroundStyle(BridgeTokens.fg4)
                    TextField("Search commands", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg2)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))

                Button {
                    createNew()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BridgeTokens.accentLink)
                        .frame(width: 30, height: 30)
                        .background(BridgeTokens.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                    .font(.system(size: 11))
                    .foregroundStyle(BridgeTokens.fg4)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(maxHeight: .infinity)
    }

    private func commandRow(_ c: CommandStore.Command) -> some View {
        Button {
            selectedSlug = c.slug
            saveMessage = nil
        } label: {
            HStack(spacing: 11) {
                iconBubble(c.icon, color: c.color, diameter: 28, glyph: 14)
                Text(c.name)
                    .font(.system(size: 13.5))
                    .foregroundStyle(BridgeTokens.fg1)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let slot = c.keySlot {
                    Text(String(slot))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(BridgeTokens.fg3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(BridgeTokens.chipFill, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(rowBackground(selected: selectedSlug == c.slug),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selectedSlug == c.slug ? BridgeTokens.hairlineStrong : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowBackground(selected: Bool) -> AnyShapeStyle {
        if selected {
            return AnyShapeStyle(LinearGradient(
                colors: [BridgeTokens.accent.opacity(0.34), BridgeTokens.accent.opacity(0.18)],
                startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(Color.clear)
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

    // Favorite-slot "keys": pronounced, square keyboard-style caps that fill
    // the row (operator feedback — "like keys on the computer"). Raised look =
    // adaptive surface + top sheen + soft drop shadow; selected lights up royal
    // blue with a brighter sheen.
    private func slotButton(slot: Int, cmd: CommandStore.Command) -> some View {
        let isMine = cmd.keySlot == slot
        let isTaken = commands.contains { $0.slug != cmd.slug && $0.keySlot == slot }
        return Button {
            setSlot(slug: cmd.slug, slot: slot)
        } label: {
            Text(String(slot))
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(isMine ? Color.white
                                 : (isTaken ? BridgeTokens.fg5 : BridgeTokens.fg2))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(slotKeyBackground(isMine: isMine, isTaken: isTaken))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isMine ? BridgeTokens.accent.opacity(0.7) : BridgeTokens.hairline,
                                      lineWidth: isMine ? 1 : 0.5)
                )
                .shadow(color: Color.black.opacity(isTaken ? 0 : 0.14), radius: 2, y: 1.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isTaken && !isMine)
        .help(isTaken ? "Slot \(slot) — taken by another command" : "Assign slot \(slot)")
    }

    /// Key-cap surface: a top-lit sheen over an adaptive raised surface so each
    /// slot reads as a physical key in both themes. Selected = royal blue lit.
    @ViewBuilder private func slotKeyBackground(isMine: Bool, isTaken: Bool) -> some View {
        if isMine {
            ZStack {
                BridgeTokens.accent.opacity(0.9)
                LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom)
            }
        } else if isTaken {
            BridgeTokens.wellFill
        } else {
            ZStack {
                BridgeTokens.bgRaised
                LinearGradient(colors: [Color.white.opacity(0.10), Color.clear],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private func bodyCard(_ c: CommandStore.Command) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("Command")
                    Spacer()
                    Text("Copied to clipboard as plain-text markdown")
                        .font(.system(size: 11))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                TextEditor(text: Binding(
                    get: { c.body },
                    set: { updateBody(slug: c.slug, body: $0) }
                ))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 150)
                .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                if let msg = saveMessage {
                    Text(msg)
                        .font(.system(size: 11))
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
                    .background(trayCanvas, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(BridgeTokens.hairline, lineWidth: 1))
                }
            }
        }
    }

    private var trayCanvas: some ShapeStyle {
        LinearGradient(
            colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private func trayBubble(_ c: CommandStore.Command) -> some View {
        let isSelected = c.slug == selectedSlug
        return iconBubble(c.icon, color: c.color, diameter: 46, glyph: 24)
            .opacity(isSelected ? 1.0 : 0.42)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 36))
                .foregroundStyle(BridgeTokens.fg4)
            Text("No command selected")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BridgeTokens.fg2)
            Text("Pick one from the list, or create a new command with the + button.")
                .font(.system(size: 12))
                .foregroundStyle(BridgeTokens.fg4)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - Icon bubble

    @ViewBuilder
    private func iconBubble(
        _ icon: CommandStore.Icon,
        color: CommandStore.NotionColor?,
        diameter: CGFloat,
        glyph: CGFloat
    ) -> some View {
        ZStack {
            Circle()
                .fill(BridgeTokens.chipFill)
                .overlay(Circle().strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
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
    }

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
