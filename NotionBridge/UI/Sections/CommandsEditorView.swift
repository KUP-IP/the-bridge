// CommandsEditorView.swift — Settings → Commands TextExpander-analog editor.
// PKT-6 UI v3.5. Wraps CommandStore CRUD into a glass-themed list + editor pane.

import SwiftUI

public struct CommandsEditorView: View {
    @State private var commands: [CommandStore.Command] = []
    @State private var selectedSlug: String? = nil
    @State private var loadError: String? = nil
    @State private var saveMessage: String? = nil
    @State private var isCreatingNew: Bool = false

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // Inner sidebar — command list
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("Search commands")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        createNew()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.black.opacity(0.18))

                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(commands, id: \.slug) { c in
                            commandRow(c)
                        }
                    }
                    .padding(6)
                }

                Divider().background(Color.white.opacity(0.08))
                HStack {
                    Text("\(commands.count) commands · \(favoriteCount) favorites")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: 240)
            .background(Color.white.opacity(0.03))
            .overlay(Divider().background(Color.white.opacity(0.10)), alignment: .trailing)

            // Editor pane
            if let cmd = currentCommand {
                ScrollView {
                    VStack(spacing: 14) {
                        editorHeader(cmd)
                        appearanceCard(cmd)
                        favoriteSlotCard(cmd)
                        nameCard(cmd)
                        bodyCard(cmd)
                    }
                    .padding(18)
                }
                .frame(maxWidth: .infinity)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
        .onChange(of: commands) { _, _ in
            if selectedSlug == nil { selectedSlug = commands.first?.slug }
        }
    }

    // MARK: - Sidebar row

    private func commandRow(_ c: CommandStore.Command) -> some View {
        Button {
            selectedSlug = c.slug
            saveMessage = nil
        } label: {
            HStack(spacing: 10) {
                iconView(c.icon, color: c.color)
                    .frame(width: 28, height: 28)
                Text(c.name)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if let slot = c.keySlot {
                    Text(String(slot))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selectedSlug == c.slug
                    ? AnyShapeStyle(LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Editor sections

    private func editorHeader(_ c: CommandStore.Command) -> some View {
        HStack(spacing: 14) {
            iconView(c.icon, color: c.color)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(Color.white.opacity(0.06))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                )
            Text(c.name)
                .font(.system(size: 22, weight: .semibold))
            Spacer()
            Button {
                Task { await duplicate(c) }
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Duplicate")

            Button(role: .destructive) {
                Task { await delete(c) }
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("Delete")
        }
    }

    private func appearanceCard(_ c: CommandStore.Command) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Appearance")
                HStack(spacing: 6) {
                    ForEach(CommandStore.NotionColor.allCases, id: \.self) { col in
                        Button {
                            updateColor(slug: c.slug, color: col)
                        } label: {
                            Circle()
                                .fill(NotionPalette.color(named: col.rawValue) ?? .gray)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().strokeBorder(
                                        c.color == col ? Color.white : Color.white.opacity(0.12),
                                        lineWidth: c.color == col ? 2 : 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("Color applies to symbols, not emoji")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Icon picker: replace from the menu bar above (current: \(c.icon.displayHint)). Full emoji + SF Symbol picker is the next iteration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func favoriteSlotCard(_ c: CommandStore.Command) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Favorite slot")
                HStack(spacing: 6) {
                    ForEach(1...9, id: \.self) { slot in
                        slotButton(slot: slot, cmd: c)
                    }
                    slotButton(slot: 0, cmd: c)
                    Button("None") {
                        setSlot(slug: c.slug, slot: nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text(slotHint(for: c))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func slotButton(slot: Int, cmd: CommandStore.Command) -> some View {
        let isMine = cmd.keySlot == slot
        let takenBy = commands.first { $0.slug != cmd.slug && $0.keySlot == slot }
        let isTaken = takenBy != nil
        return Button {
            setSlot(slug: cmd.slug, slot: slot)
        } label: {
            Text(String(slot))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 36, height: 36)
                .background(
                    isMine
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color.black.opacity(0.18)),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            isMine ? Color.white.opacity(0.30) : Color.white.opacity(0.10),
                            lineWidth: isMine ? 1 : 0.5
                        )
                )
                .foregroundStyle(isMine ? .primary : (isTaken ? .secondary : .primary))
                .opacity(isTaken && !isMine ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private func slotHint(for c: CommandStore.Command) -> String {
        if let s = c.keySlot {
            return "Press \(s) while Command Bridge is open to fire this command. Greyed slots are held by other commands — clicking reassigns."
        } else {
            return "Pick a 0–9 slot to make this command fireable from the Command Bridge popup."
        }
    }

    private func nameCard(_ c: CommandStore.Command) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Name")
                TextField("Command name", text: Binding(
                    get: { c.name },
                    set: { newName in updateName(slug: c.slug, name: newName) }
                ))
                .textFieldStyle(.roundedBorder)
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: Binding(
                    get: { c.body },
                    set: { newBody in updateBody(slug: c.slug, body: newBody) }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                if let msg = saveMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No command selected")
                .font(.headline)
            Text("Pick one from the list, or create a new command with the + button.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    @ViewBuilder
    private func iconView(_ icon: CommandStore.Icon, color: CommandStore.NotionColor?) -> some View {
        switch icon {
        case .emoji(let s):
            Text(s).font(.system(size: 18))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color.flatMap { NotionPalette.color(named: $0.rawValue) } ?? .primary)
        }
    }

    // MARK: - Computed

    private var currentCommand: CommandStore.Command? {
        commands.first(where: { $0.slug == selectedSlug })
    }

    private var favoriteCount: Int { commands.filter { $0.keySlot != nil }.count }

    // MARK: - Mutations

    private func load() async {
        do {
            try CommandStore.shared.seedIfEmpty()
            let list = try CommandStore.shared.list()
            await MainActor.run {
                self.commands = list
                if self.selectedSlug == nil { self.selectedSlug = list.first?.slug }
                self.loadError = nil
            }
        } catch {
            await MainActor.run { self.loadError = error.localizedDescription }
        }
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

    private func updateColor(slug: String, color: CommandStore.NotionColor) {
        guard var c = commands.first(where: { $0.slug == slug }) else { return }
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

    private func duplicate(_ c: CommandStore.Command) async {
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

    private func delete(_ c: CommandStore.Command) async {
        do {
            try CommandStore.shared.delete(slug: c.slug)
            let list = try CommandStore.shared.list()
            await MainActor.run {
                self.commands = list
                self.selectedSlug = list.first?.slug
            }
        } catch {
            saveMessage = error.localizedDescription
        }
    }
}
