// SkillsView.swift — Skills Tab in Settings (twin master–detail redesign)
// NotionBridge · UI
// PKT-366 F9: Skills configuration UI with add/remove/toggle.
// PKT-366 F11: Cross-tab dependency guard (fetch_skill disabled warning).
// PKT-487: Clickable names, inline URL edit, reorder, sort alphabetically.
// v3.7.2 bundle-2 redesign: twin master–detail to match the locked mockup
//   (design/.../the-bridge/Skills.jsx). A skill list (left) + a detail pane
//   (right) with a routing-metadata grid, trigger / anti-trigger chips, a body
//   preview, and the Routing / Palette permission toggles. Every binding —
//   SkillsManager CRUD, routing/palette flags, inline URL editing, platform
//   badge, reorder + delete + rename, file-source skills, add form — is
//   preserved verbatim; only the view layer was restructured.

import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Skills tab for the Settings window — twin master–detail.
struct SkillsView: View {
    let skillsManager: SkillsManager

    /// F11: Whether `fetch_skill` is currently disabled in the Tools tab.
    var fetchSkillDisabled: Bool = false

    // MARK: - Selection (master → detail)

    /// A selected row is either a Notion-source skill (by name) or a
    /// file-source skill (by absolute path). `nil` = nothing selected /
    /// add-mode active.
    private enum Selection: Equatable {
        case skill(String)
        case file(String) // path.path
    }
    @State private var selection: Selection?
    @State private var searchText: String = ""
    @State private var showAddForm: Bool = false

    // MARK: - Add-skill form state (unchanged bindings)

    @State private var newSkillName: String = ""
    @State private var newSkillPageId: String = ""
    @State private var newSkillURL: String = ""
    @State private var newSkillVisibility: SkillVisibility = .standard
    @State private var detectedPlatform: SkillPlatform = .manual
    @State private var addError: String?
    @State private var urlValidationError: String?

    // PKT-487: Inline URL editing state
    @State private var editingSkillName: String?
    @State private var editingURL: String = ""

    // W2 D7: file-source skills (read-only metadata; toggles persist per path).
    @State private var fileSourceSkills: [ParsedSkill] = []
    @State private var fileSkillEnabledMap: [String: Bool] = [:]
    @State private var fileSkillRoutingMap: [String: Bool] = [:]
    @State private var fileSkillPaletteMap: [String: Bool] = [:]

    // W4 (3.4.1): independent routing / palette toggles on the add form.
    @State private var newSkillRoutingDiscoverable: Bool = false
    @State private var newSkillInCommandPalette: Bool = false
    /// W4 (3.4.1): per-row delete confirmation.
    @State private var skillPendingDeletion: String?

    // BUG-2 fix: Inline skill name rename state
    @State private var renamingSkillName: String?
    @State private var renameText: String = ""
    @State private var renameError: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            banners
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 268)
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 0.5)
                detailColumn
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 560)
        }
        .onAppear {
            skillsManager.reloadFromUserDefaults()
            loadFileSourceSkills()
            restoreSelectionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notionBridgeSkillsStorageDidChange)) { _ in
            skillsManager.reloadFromUserDefaults()
            restoreSelectionIfNeeded()
        }
        // W4 (3.4.1): destructive delete behind a confirmation alert.
        .alert("Delete this skill?",
               isPresented: Binding(
                get: { skillPendingDeletion != nil },
                set: { if !$0 { skillPendingDeletion = nil } }
               ),
               presenting: skillPendingDeletion) { name in
            Button("Delete \(name)", role: .destructive) {
                skillsManager.removeSkill(named: name)
                if selection == .skill(name) { selection = nil }
                skillPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                skillPendingDeletion = nil
            }
        } message: { name in
            Text("\"\(name)\" will be removed from this Notion Bridge install. The underlying Notion page is not affected. This action cannot be undone from this dialog.")
        }
    }

    // MARK: - Banners (cross-tab guards — unchanged semantics)

    @ViewBuilder
    private var banners: some View {
        let invalidPageSkills = skillsManager.skills.filter { !NotionPageRef.isValidStoredPageId($0.notionPageId) }
        let palettePopulation = skillsManager.skills.filter { $0.enabled && $0.inCommandPalette }.count
            + fileSourceSkills.filter { (fileSkillEnabledMap[$0.path.path] ?? true) && (fileSkillPaletteMap[$0.path.path] ?? false) }.count

        VStack(spacing: 8) {
            if !invalidPageSkills.isEmpty {
                inlineBanner(
                    "Some skills have an invalid Notion page ID (not 32 hex digits). Fix the URL or ID — these skills won\u{2019}t be retrievable by agents until corrected.",
                    tone: .warn)
            }
            if fetchSkillDisabled && !skillsManager.skills.isEmpty {
                inlineBanner(
                    "Skill retrieval is disabled in Tools. Skills won\u{2019}t be available to AI clients until you re-enable it.",
                    tone: .warn)
            }
            if !skillsManager.skills.isEmpty && palettePopulation == 0 {
                inlineBanner(
                    "No skills in the Commands palette yet. Flip a skill\u{2019}s Palette toggle to make it appear in the global hot-key popover. Routing is independent.",
                    tone: .info)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, fetchSkillDisabled || !invalidPageSkills.isEmpty || (!skillsManager.skills.isEmpty && palettePopulation == 0) ? 12 : 0)
    }

    private enum BannerTone { case warn, info }
    private func inlineBanner(_ text: String, tone: BannerTone) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(tone == .warn ? BridgeTokens.warn : BridgeTokens.accentLink)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background((tone == .warn ? BridgeTokens.warn : BridgeTokens.accent).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder((tone == .warn ? BridgeTokens.warn : BridgeTokens.accent).opacity(0.30), lineWidth: 0.5))
    }

    // MARK: - LIST COLUMN (master)

    private var listColumn: some View {
        VStack(spacing: 0) {
            // search + add
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg4)
                    TextField("Search skills…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg1)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))

                Button {
                    showAddForm = true
                    selection = nil
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(showAddForm ? Color.white : BridgeTokens.fg2)
                        .frame(width: 32, height: 32)
                        .background(showAddForm ? BridgeTokens.accent.opacity(0.85) : Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Add a new skill")
            }
            .padding(.horizontal, 12).padding(.vertical, 11)

            Divider().overlay(Color.white.opacity(0.08))

            // list
            ScrollView {
                LazyVStack(spacing: 2) {
                    let notionRows = filteredSkills
                    ForEach(Array(notionRows.enumerated()), id: \.element.id) { _, skill in
                        skillListRow(skill)
                    }

                    if !filteredFileSkills.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 9))
                            Text("FILE-SOURCE")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1.0)
                            Spacer()
                            Text("\(fileSourceSkills.count)")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(BridgeTokens.fg4)
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)

                        ForEach(filteredFileSkills, id: \.path) { fs in
                            fileListRow(fs)
                        }
                    }

                    if filteredSkills.isEmpty && filteredFileSkills.isEmpty {
                        emptyListState
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
            }

            Divider().overlay(Color.white.opacity(0.08))

            // footer count
            HStack {
                Text(listFooterText)
                    .font(.system(size: 11))
                    .foregroundStyle(BridgeTokens.fg4)
                Spacer()
                if !skillsManager.skills.isEmpty {
                    Button {
                        commitPendingEdit()
                        skillsManager.sortAlphabetically()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11))
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                    .buttonStyle(.plain)
                    .help("Sort alphabetically")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .background(Color.black.opacity(0.10))
    }

    private var emptyListState: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.system(size: 28))
                .foregroundStyle(BridgeTokens.fg5)
            Text(searchText.isEmpty ? "No skills configured" : "No matches")
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg3)
            if searchText.isEmpty {
                Text("Skills are Notion pages and SKILL.md files that AI clients can request by name.")
                    .font(.system(size: 11))
                    .foregroundStyle(BridgeTokens.fg4)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.vertical, 26)
    }

    private var listFooterText: String {
        let total = skillsManager.skills.count
        let enabled = skillsManager.enabledSkills.count
        let routing = skillsManager.skills.filter { $0.enabled && $0.routingDiscoverable }.count
        if total == 0 { return "No skills" }
        return "\(enabled)/\(total) enabled · \(routing) routing"
    }

    /// One master row: avatar + name + platform tag + status dot.
    private func skillListRow(_ skill: SkillsManager.Skill) -> some View {
        let isSel = selection == .skill(skill.name)
        return Button {
            commitPendingEdit()
            showAddForm = false
            selection = .skill(skill.name)
        } label: {
            HStack(spacing: 10) {
                avatar(systemImage: skill.platform.systemImage, big: false,
                       dimmed: !skill.enabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 13))
                        .foregroundStyle(skill.enabled ? BridgeTokens.fg1 : BridgeTokens.fg4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(skill.platform.displayName.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(BridgeTokens.fg5)
                }
                Spacer(minLength: 4)
                statusDot(for: skill)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(rowBackground(selected: isSel))
            .overlay(rowRim(selected: isSel))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileListRow(_ fs: ParsedSkill) -> some View {
        let isSel = selection == .file(fs.path.path)
        let enabled = fileSkillEnabledMap[fs.path.path] ?? true
        return Button {
            commitPendingEdit()
            showAddForm = false
            selection = .file(fs.path.path)
        } label: {
            HStack(spacing: 10) {
                avatar(systemImage: "doc.text", big: false, dimmed: !enabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fs.name)
                        .font(.system(size: 13))
                        .foregroundStyle(enabled ? BridgeTokens.fg1 : BridgeTokens.fg4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(fs.isUserSource ? "USER FILE" : "BUNDLED")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(BridgeTokens.fg5)
                }
                Spacer(minLength: 4)
                Circle()
                    .fill(enabled ? BridgeTokens.ok : BridgeTokens.fg5)
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(rowBackground(selected: isSel))
            .overlay(rowRim(selected: isSel))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Status dot: emerald when routing-discoverable, amber when palette-only,
    /// blue-grey when enabled-but-neither, faint when disabled.
    private func statusDot(for skill: SkillsManager.Skill) -> some View {
        let color: Color = {
            if !skill.enabled { return BridgeTokens.fg5 }
            if skill.routingDiscoverable { return BridgeTokens.ok }
            if skill.inCommandPalette { return BridgeTokens.warn }
            return BridgeTokens.accentLink
        }()
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: 3)
    }

    private func rowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(selected
                  ? LinearGradient(colors: [BridgeTokens.accent.opacity(0.30), BridgeTokens.accent.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom)
                  : LinearGradient(colors: [Color.clear, Color.clear], startPoint: .top, endPoint: .bottom))
    }

    private func rowRim(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Color.white.opacity(0.14) : Color.clear, lineWidth: 0.5)
    }

    private func avatar(systemImage: String, big: Bool, dimmed: Bool) -> some View {
        let dim: CGFloat = big ? 48 : 28
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.34), Color.white.opacity(0.06), Color.clear],
                        center: UnitPoint(x: 0.3, y: 0.18),
                        startRadius: 0, endRadius: dim * 0.9)
                )
                .background(Circle().fill(Color.white.opacity(0.06)))
            Circle().strokeBorder(Color.white.opacity(big ? 0.18 : 0.14), lineWidth: 0.5)
            Image(systemName: systemImage)
                .font(.system(size: big ? 19 : 12, weight: .medium))
                .foregroundStyle(dimmed ? BridgeTokens.fg4 : BridgeTokens.fg1)
        }
        .frame(width: dim, height: dim)
        .opacity(dimmed ? 0.55 : 1)
    }

    // MARK: - DETAIL COLUMN

    @ViewBuilder
    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch selection {
                case .skill(let name):
                    if let skill = skillsManager.skill(named: name) {
                        notionDetail(skill)
                    } else {
                        detailPlaceholder
                    }
                case .file(let path):
                    if let fs = fileSourceSkills.first(where: { $0.path.path == path }) {
                        fileDetail(fs)
                    } else {
                        detailPlaceholder
                    }
                case .none:
                    if showAddForm {
                        addSkillForm
                    } else {
                        detailPlaceholder
                    }
                }
            }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 22, trailing: 22))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailPlaceholder: some View {
        VStack(spacing: 14) {
            avatar(systemImage: "sparkles", big: true, dimmed: false)
            Text(skillsManager.skills.isEmpty && fileSourceSkills.isEmpty
                 ? "No skills yet"
                 : "Select a skill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BridgeTokens.fg2)
            Text(skillsManager.skills.isEmpty && fileSourceSkills.isEmpty
                 ? "Add a skill with the + button. Skills are documents AI clients can request by name when they need them."
                 : "Pick a skill from the list to view its routing metadata, triggers, and body preview.")
                .font(.system(size: 12))
                .foregroundStyle(BridgeTokens.fg4)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button {
                showAddForm = true
                selection = nil
            } label: {
                Label("Add a skill", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(BridgeTokens.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 460)
        .padding(.top, 60)
    }

    // MARK: - Notion-source detail

    @ViewBuilder
    private func notionDetail(_ skill: SkillsManager.Skill) -> some View {
        // header: avatar + name (rename) + slug/url + actions
        detailHeader(skill)

        // routing metadata grid
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Routing metadata")
                metadataGrid(skill)
            }
        }

        // triggers / anti-triggers
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Triggers")
                if skill.triggerPhrases.isEmpty {
                    emptyHint("No trigger phrases. Add them with the `manage_skill` MCP tool to surface this skill in routing.")
                } else {
                    chipFlow(skill.triggerPhrases, anti: false)
                }
                if !skill.antiTriggerPhrases.isEmpty {
                    BridgeCardLabel("Anti-triggers")
                        .padding(.top, 4)
                    chipFlow(skill.antiTriggerPhrases, anti: true)
                }
            }
        }

        // body preview
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    BridgeCardLabel("Summary")
                    Spacer()
                    Text(skill.platform.displayName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                if skill.summary.isEmpty {
                    emptyHint("No summary set. The summary is the one-line description agents see in the routing list.")
                } else {
                    ScrollView {
                        SOMarkdownView(markdown: skill.summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(maxHeight: 200)
                    .background(BridgeTokens.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(BridgeTokens.accent.opacity(0.24), lineWidth: 0.5))
                }
            }
        }

        // permissions & behavior (Routing + Palette toggles)
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 0) {
                BridgeCardLabel("Permissions & behavior")
                    .padding(.bottom, 10)
                permissionToggleRow(
                    title: "Enabled",
                    sub: "When off, the skill is hidden from every surface and is not retrievable by name.",
                    isOn: Binding(
                        get: { skill.enabled },
                        set: { _ in skillsManager.toggleSkill(named: skill.name) }
                    ))
                tokenDivider
                permissionToggleRow(
                    title: "Auto-load into routing context",
                    sub: "Include this skill in `list_routing_skills` so MCP clients can discover it by name.",
                    isOn: Binding(
                        get: { skill.routingDiscoverable },
                        set: { _ = skillsManager.setRoutingDiscoverable(named: skill.name, to: $0) }
                    ))
                tokenDivider
                permissionToggleRow(
                    title: "Show in Commands palette",
                    sub: "Appear in the global hot-key popover (copies the page body to your clipboard).",
                    isOn: Binding(
                        get: { skill.inCommandPalette },
                        set: { _ = skillsManager.setInCommandPalette(named: skill.name, to: $0) }
                    ))
            }
        }
    }

    private func detailHeader(_ skill: SkillsManager.Skill) -> some View {
        HStack(alignment: .top, spacing: 14) {
            avatar(systemImage: skill.platform.systemImage, big: true, dimmed: !skill.enabled)

            VStack(alignment: .leading, spacing: 4) {
                // name + rename
                if renamingSkillName == skill.name {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Skill name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: 280)
                            .onSubmit { commitRename(for: skill.name) }
                            .onExitCommand { renamingSkillName = nil; renameError = nil }
                        if let renameError {
                            Text(renameError).font(.system(size: 11)).foregroundStyle(BridgeTokens.bad)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(BridgeTokens.fg1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Button {
                            commitPendingEdit()
                            renameError = nil
                            renamingSkillName = skill.name
                            renameText = skill.name
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(BridgeTokens.fg4)
                        }
                        .buttonStyle(.plain)
                        .help("Rename")
                    }
                }

                // url / id row (inline edit)
                idRow(skill)
            }

            Spacer(minLength: 8)

            // actions: open, reorder, delete
            detailActions(skill)
        }
    }

    @ViewBuilder
    private func idRow(_ skill: SkillsManager.Skill) -> some View {
        if editingSkillName == skill.name {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Notion URL or UUID", text: $editingURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: 320)
                    .onSubmit { commitURLEdit(for: skill.name) }
                    .onExitCommand { editingSkillName = nil; urlValidationError = nil }
                if let urlValidationError {
                    Text(urlValidationError).font(.system(size: 11)).foregroundStyle(BridgeTokens.bad)
                }
            }
        } else {
            HStack(spacing: 8) {
                BridgeBadge(skill.platform.displayName, systemImage: skill.platform.systemImage)
                Button {
                    commitPendingEdit()
                    urlValidationError = nil
                    editingSkillName = skill.name
                    editingURL = skill.notionPageId
                } label: {
                    if skill.notionPageId.isEmpty {
                        Label("Set URL", systemImage: "link.badge.plus")
                            .font(.system(size: 11))
                            .foregroundStyle(BridgeTokens.warn)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "link").font(.system(size: 9))
                            Text("ID …\(String(skill.notionPageId.suffix(6)))")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(BridgeTokens.fg3)
                    }
                }
                .buttonStyle(.plain)
                .help(skill.notionPageId.isEmpty
                      ? "Add a Notion page URL or UUID for this skill"
                      : "Click to edit the URL or UUID")
            }
        }
    }

    private func detailActions(_ skill: SkillsManager.Skill) -> some View {
        let index = skillsManager.skills.firstIndex(where: { $0.id == skill.id }) ?? 0
        return HStack(spacing: 4) {
            iconButton("arrow.up.right.square", help: "Open in browser") {
                openSkillURL(skill.url ?? skill.notionPageId)
            }
            iconButton("chevron.up", help: "Move up", disabled: index == 0) {
                commitPendingEdit()
                skillsManager.moveSkill(from: index, to: index - 1)
            }
            iconButton("chevron.down", help: "Move down",
                       disabled: index == skillsManager.skills.count - 1) {
                commitPendingEdit()
                skillsManager.moveSkill(from: index, to: index + 1)
            }
            iconButton("trash", help: "Delete skill", danger: true) {
                skillPendingDeletion = skill.name
            }
        }
    }

    private func metadataGrid(_ skill: SkillsManager.Skill) -> some View {
        let cells: [(String, String)] = [
            ("Platform", skill.platform.displayName),
            ("Status", skill.enabled ? "Enabled" : "Disabled"),
            ("Visibility", visibilityLabel(skill)),
            ("Triggers", "\(skill.triggerPhrases.count)"),
            ("Anti-triggers", "\(skill.antiTriggerPhrases.count)"),
            ("Page ID", skill.notionPageId.isEmpty ? "—" : "…\(String(skill.notionPageId.suffix(6)))"),
            ("In palette", skill.inCommandPalette ? "Yes" : "No"),
            ("In routing", skill.routingDiscoverable ? "Yes" : "No"),
        ]
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4),
            spacing: 9
        ) {
            ForEach(cells, id: \.0) { cap, val in
                metaCell(cap: cap, val: val)
            }
        }
    }

    private func metaCell(cap: String, val: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(cap.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(BridgeTokens.fg4)
            Text(val)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BridgeTokens.fg1)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func visibilityLabel(_ skill: SkillsManager.Skill) -> String {
        switch (skill.routingDiscoverable, skill.inCommandPalette) {
        case (true, true):   return "Both"
        case (true, false):  return "Routing"
        case (false, true):  return "Palette"
        case (false, false): return "Fetch-only"
        }
    }

    // MARK: - File-source detail

    @ViewBuilder
    private func fileDetail(_ fs: ParsedSkill) -> some View {
        let enabled = fileSkillEnabledMap[fs.path.path] ?? true
        let summary: String = {
            if case .string(let d) = fs.frontmatter["description"] { return d }
            return ""
        }()

        // header
        HStack(alignment: .top, spacing: 14) {
            avatar(systemImage: "doc.text", big: true, dimmed: !enabled)
            VStack(alignment: .leading, spacing: 4) {
                Text(fs.name)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                    .lineLimit(1)
                BridgeBadge(fs.isUserSource ? "User file" : "Bundled",
                            systemImage: fs.isUserSource ? "person" : "shippingbox",
                            tone: fs.isUserSource ? .info : .neutral)
            }
            Spacer(minLength: 8)
            iconButton("folder", help: "Reveal SKILL.md in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fs.path])
            }
        }

        // metadata: path + source
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("File metadata")
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2),
                    spacing: 9
                ) {
                    metaCell(cap: "Source", val: fs.isUserSource ? "User dir" : "Bundled")
                    metaCell(cap: "Status", val: enabled ? "Enabled" : "Disabled")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("PATH")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(BridgeTokens.fg4)
                    Text(fs.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(BridgeTokens.fg3)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)
            }
        }

        // summary / body preview
        if !summary.isEmpty {
            BridgeGlassCard {
                VStack(alignment: .leading, spacing: 9) {
                    BridgeCardLabel("Summary")
                    Text(summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        // permission toggles (file-source — persist per path)
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 0) {
                BridgeCardLabel("Permissions & behavior")
                    .padding(.bottom, 10)
                permissionToggleRow(
                    title: "Enabled",
                    sub: "Stores a per-path enable flag. Toggling here does NOT modify the SKILL.md file.",
                    isOn: Binding(
                        get: { fileSkillEnabledMap[fs.path.path] ?? true },
                        set: { v in
                            fileSkillEnabledMap[fs.path.path] = v
                            SkillsModule.setFileSkillEnabled(path: fs.path, enabled: v)
                        }
                    ))
                tokenDivider
                permissionToggleRow(
                    title: "Auto-load into routing context",
                    sub: "Include this file-source skill in the merged routing discovery list.",
                    isOn: Binding(
                        get: { fileSkillRoutingMap[fs.path.path] ?? false },
                        set: { v in
                            fileSkillRoutingMap[fs.path.path] = v
                            SkillsModule.setFileSkillRoutingDiscoverable(path: fs.path, value: v)
                        }
                    ))
                tokenDivider
                permissionToggleRow(
                    title: "Show in Commands palette",
                    sub: "Stage palette membership. Advisory for file-source skills until the commit pipeline lands.",
                    isOn: Binding(
                        get: { fileSkillPaletteMap[fs.path.path] ?? false },
                        set: { v in
                            fileSkillPaletteMap[fs.path.path] = v
                            SkillsModule.setFileSkillInCommandPalette(path: fs.path, value: v)
                        }
                    ))
            }
        }
    }

    // MARK: - Add-skill form (detail pane)

    private var addSkillForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                avatar(systemImage: "plus", big: true, dimmed: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a skill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text("Add a Notion or Google Docs URL to auto-detect the platform, or enter a UUID manually.")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                Button {
                    showAddForm = false
                    resetAddForm()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }

            BridgeGlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    formField("Name") {
                        TextField("Skill name", text: $newSkillName)
                            .textFieldStyle(.roundedBorder)
                    }
                    formField("URL") {
                        TextField("https://www.notion.so/…", text: $newSkillURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: newSkillURL) { _, newValue in
                                autoDetectFromURL(newValue)
                            }
                    }
                    formField("UUID / Page ID") {
                        HStack(spacing: 8) {
                            TextField("32-hex UUID", text: $newSkillPageId)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            BridgeBadge(detectedPlatform.displayName, systemImage: detectedPlatform.systemImage)
                        }
                    }

                    tokenDivider

                    permissionToggleRow(
                        title: "Show in routing discovery list",
                        sub: "Agents can discover this skill by name without downloading the full page first.",
                        isOn: $newSkillRoutingDiscoverable)
                    permissionToggleRow(
                        title: "Show in Commands palette",
                        sub: "The global hot-key popover copies the page body to your clipboard.",
                        isOn: $newSkillInCommandPalette)

                    if let addError {
                        Text(addError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.bad)
                    }

                    HStack {
                        Spacer()
                        Button("Add skill") { addSkill() }
                            .buttonStyle(.borderedProminent)
                            .tint(BridgeTokens.accent)
                            .disabled(newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || newSkillPageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            BridgeGlassCard {
                VStack(alignment: .leading, spacing: 7) {
                    BridgeCardLabel("How visibility works")
                    helpLine("Routing", "appears in the routing discovery list so agents can find it by name.")
                    helpLine("Palette", "appears in the global Commands palette hot-key popover.")
                    Text("Routing and Palette are independent — a skill may be in both, either, or neither. Skills in neither surface are still retrievable by name.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg4)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func formField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                .foregroundStyle(BridgeTokens.fg4)
            content()
        }
    }

    private func helpLine(_ term: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(term)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(BridgeTokens.accentLink)
            Text("— \(desc)")
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg3)
        }
    }

    // MARK: - Shared detail bits

    private func chipFlow(_ phrases: [String], anti: Bool) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(phrases, id: \.self) { p in
                Text(p)
                    .font(.system(size: 12))
                    .foregroundStyle(anti ? BridgeTokens.badText : BridgeTokens.fg2)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(
                        (anti ? BridgeTokens.bad.opacity(0.10) : Color.white.opacity(0.05)),
                        in: Capsule())
                    .overlay(Capsule().strokeBorder(
                        anti ? BridgeTokens.bad.opacity(0.26) : Color.white.opacity(0.10),
                        lineWidth: 0.5))
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(BridgeTokens.fg4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var tokenDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.vertical, 10)
    }

    private func permissionToggleRow(title: String, sub: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(BridgeTokens.accent)
        }
    }

    private func iconButton(_ systemImage: String, help: String, disabled: Bool = false, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(danger ? BridgeTokens.bad.opacity(0.85) : BridgeTokens.fg3)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
    }

    // MARK: - Filtering

    private var filteredSkills: [SkillsManager.Skill] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return skillsManager.skills }
        return skillsManager.skills.filter {
            $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q)
        }
    }

    private var filteredFileSkills: [ParsedSkill] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return fileSourceSkills }
        return fileSourceSkills.filter { $0.name.lowercased().contains(q) }
    }

    private func restoreSelectionIfNeeded() {
        // If current selection vanished (deleted / renamed), clear it.
        switch selection {
        case .skill(let name):
            if skillsManager.skill(named: name) == nil { selection = nil }
        case .file(let path):
            if !fileSourceSkills.contains(where: { $0.path.path == path }) { /* keep until reload */ }
        case .none:
            break
        }
    }

    // MARK: - File-source load (unchanged)

    private func loadFileSourceSkills() {
        Task {
            let skills = await FilesystemSkillIndex.shared.allSkills()
            var enabledMap: [String: Bool] = [:]
            var routingMap: [String: Bool] = [:]
            var paletteMap: [String: Bool] = [:]
            for s in skills {
                enabledMap[s.path.path] = SkillsModule.isFileSkillEnabled(path: s.path)
                let fm = s.frontmatter.compactMapValues { value -> Any? in
                    if case .string(let v) = value { return v }
                    return nil
                }
                routingMap[s.path.path] = SkillsModule.isFileSkillRoutingDiscoverable(path: s.path, frontmatter: fm)
                paletteMap[s.path.path] = SkillsModule.isFileSkillInCommandPalette(path: s.path)
            }
            await MainActor.run {
                self.fileSourceSkills = skills
                self.fileSkillEnabledMap = enabledMap
                self.fileSkillRoutingMap = routingMap
                self.fileSkillPaletteMap = paletteMap
            }
        }
    }

    // MARK: - Actions (PKT-487) — unchanged

    private func openSkillURL(_ urlString: String) {
        let candidate: String
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            candidate = urlString
        } else if !urlString.isEmpty {
            let hex = urlString.replacingOccurrences(of: "-", with: "")
            candidate = "https://www.notion.so/\(hex)"
        } else {
            return
        }
        guard let url = URL(string: candidate) else { return }
        NSWorkspace.shared.open(url)
    }

    private func commitRename(for skillName: String) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renameError = "Name cannot be empty."
            return
        }
        let success = skillsManager.renameSkill(named: skillName, to: trimmed)
        if success {
            // keep the renamed skill selected
            if selection == .skill(skillName) { selection = .skill(trimmed) }
            renamingSkillName = nil
            renameError = nil
        } else {
            renameError = "A skill with this name already exists."
        }
    }

    private func commitPendingEdit() {
        if let name = editingSkillName {
            commitURLEdit(for: name)
        }
        if let name = renamingSkillName {
            commitRename(for: name)
        }
    }

    private func commitURLEdit(for skillName: String) {
        let trimmed = editingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        switch NotionPageRef.normalizedPageId(from: trimmed) {
        case .success(let normalized):
            skillsManager.updateSkillURL(named: skillName, newPageId: normalized)
            editingSkillName = nil
            urlValidationError = nil
        case .failure(let err):
            urlValidationError = err.message
        }
    }

    // MARK: - Add Skill — unchanged logic

    private func autoDetectFromURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            detectedPlatform = .manual
            return
        }
        switch SkillURLParser.parse(url: trimmed) {
        case .success(let parsed):
            newSkillPageId = parsed.uuid
            detectedPlatform = parsed.platform
            addError = nil
        case .failure:
            detectedPlatform = SkillURLParser.detectPlatform(from: trimmed)
        }
    }

    private func addSkill() {
        addError = nil
        let name = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageId = newSkillPageId.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlValue = newSkillURL.trimmingCharacters(in: .whitespacesAndNewlines)

        let platform = detectedPlatform != .manual ? detectedPlatform : .notion
        let storedURL: String? = urlValue.isEmpty ? nil : urlValue

        if platform == .notion {
            switch NotionPageRef.normalizedPageId(from: pageId) {
            case .failure(let err):
                addError = err.message
                return
            case .success(let normalized):
                let success = skillsManager.addSkill(name: name, notionPageId: normalized, visibility: newSkillVisibility)
                if success {
                    _ = skillsManager.setRoutingDiscoverable(named: name, to: newSkillRoutingDiscoverable)
                    _ = skillsManager.setInCommandPalette(named: name, to: newSkillInCommandPalette)
                    if storedURL != nil || platform != .notion {
                        skillsManager.updateSkillExtras(named: name, url: storedURL, platform: platform)
                    }
                    finishAdd(selecting: name)
                } else {
                    addError = "A skill with this name already exists."
                }
            }
        } else {
            guard !pageId.isEmpty else {
                addError = "UUID is required."
                return
            }
            let success = skillsManager.addSkill(name: name, notionPageId: pageId, visibility: newSkillVisibility)
            if success {
                _ = skillsManager.setRoutingDiscoverable(named: name, to: newSkillRoutingDiscoverable)
                _ = skillsManager.setInCommandPalette(named: name, to: newSkillInCommandPalette)
                skillsManager.updateSkillExtras(named: name, url: storedURL, platform: platform)
                finishAdd(selecting: name)
            } else {
                addError = "A skill with this name already exists."
            }
        }
    }

    private func finishAdd(selecting name: String) {
        resetAddForm()
        showAddForm = false
        selection = .skill(name)
    }

    private func resetAddForm() {
        newSkillName = ""
        newSkillPageId = ""
        newSkillURL = ""
        newSkillVisibility = .standard
        newSkillRoutingDiscoverable = false
        newSkillInCommandPalette = false
        detectedPlatform = .manual
        addError = nil
        urlValidationError = nil
    }
}

// MARK: - FlowLayout (trigger / anti-trigger chip wrapping)

/// Minimal flow layout: lays children left-to-right, wrapping to a new line
/// when the row would overflow. Used for the trigger / anti-trigger chip rows
/// (the `.sk-chips` flex-wrap idiom from skills.css).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x - bounds.minX + size.width > maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
