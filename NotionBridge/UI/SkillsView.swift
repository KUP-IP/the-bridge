// SkillsView.swift — Skills Tab in Settings
// NotionBridge · UI
// PKT-366 F9: Skills configuration UI with add/remove/toggle.
// PKT-366 F11: Cross-tab dependency guard (fetch_skill disabled warning).
// PKT-487: Clickable names, inline URL edit, reorder, sort alphabetically.

import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Skills tab for the Settings window.
///
/// PKT-366 F9: Each row shows skill name + Notion page ID + on/off toggle.
/// "Add Skill" inline form with unique name enforcement.
/// PKT-366 F11: Warning banner if `fetch_skill` is disabled in Tools AND skills exist.
/// PKT-487: Interactive management — clickable names, inline URL edit, reorder, sort.
struct SkillsView: View {
    let skillsManager: SkillsManager

    /// F11: Whether `fetch_skill` is currently disabled in the Tools tab.
    var fetchSkillDisabled: Bool = false

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

    // W2 D7: file-source skills surface as a separate read-only section
    // populated from FilesystemSkillIndex.shared. Toggling them writes to
    // BridgeDefaults.fileSkillEnabled (per-path) — the SKILL.md itself is
    // the source of truth.
    @State private var fileSourceSkills: [ParsedSkill] = []
    @State private var fileSkillEnabledMap: [String: Bool] = [:]
    /// W4 (3.4.1): per-path mirrors of the file-source flag toggles —
    /// hydrate at load (explicit override → frontmatter default), persist
    /// via SkillsModule.set… on each user toggle.
    @State private var fileSkillRoutingMap: [String: Bool] = [:]
    @State private var fileSkillPaletteMap: [String: Bool] = [:]
    /// W4 (3.4.1): replace the legacy add-form picker with two
    /// independent toggles so the new combined state (both true) can be
    /// expressed at creation time.
    @State private var newSkillRoutingDiscoverable: Bool = false
    @State private var newSkillInCommandPalette: Bool = false
    /// W4 (3.4.1): per-row delete confirmation.
    @State private var skillPendingDeletion: String?

    // BUG-2 fix: Inline skill name rename state
    @State private var renamingSkillName: String?
    @State private var renameText: String = ""
    @State private var renameError: String?

    var body: some View {
        Form {
            let invalidPageSkills = skillsManager.skills.filter { !NotionPageRef.isValidStoredPageId($0.notionPageId) }
            if !invalidPageSkills.isEmpty {
                Section {
                    Label(
                        "Some skills have an invalid Notion page ID (not 32 hex digits). Fix the URL or ID below — these skills won't be retrievable by agents until corrected.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            // F11: Cross-tab dependency guard
            if fetchSkillDisabled && !skillsManager.skills.isEmpty {
                Section {
                    Label("Skill retrieval is disabled in Tools. Skills won\u{2019}t be available to AI clients until you re-enable it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            // W4 (3.4.1): empty-state banner — surface the silent-fail
            // condition (palette would render empty even after the
            // hot-key binds). Renders only when there are skills but 0
            // are flagged for the palette.
            let palettePopulation = skillsManager.skills.filter { $0.enabled && $0.inCommandPalette }.count
                + fileSourceSkills.filter { (fileSkillEnabledMap[$0.path.path] ?? true) && (fileSkillPaletteMap[$0.path.path] ?? false) }.count
            if !skillsManager.skills.isEmpty && palettePopulation == 0 {
                Section {
                    BridgeEmptyState(
                        systemImage: "command",
                        title: "No skills in the Commands palette yet",
                        body: "Flip a skill's Palette toggle on the right to make it appear in the global hot-key popover. Routing is independent — a skill can be in both, either, or neither."
                    )
                }
            }

            // Skill list
            if skillsManager.skills.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 36))
                            .foregroundStyle(.gray.opacity(0.5))
                        Text("No skills configured")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Skills are Notion pages and SKILL.md files that AI clients can request by name when they need them.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    ForEach(Array(skillsManager.skills.enumerated()), id: \.element.id) { index, skill in
                        skillRow(skill, at: index)
                    }
                } header: {
                    HStack {
                        Text("Skills")
                            .font(.headline)
                        Spacer()
                        // PKT-487: Sort alphabetically action
                        Button {
                            commitPendingEdit()
                            skillsManager.sortAlphabetically()
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Sort alphabetically")
                        Text("\(skillsManager.enabledSkills.count)/\(skillsManager.skills.count) enabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // W2 D7: file-source skills section (bundled + user dir).
            // Read-only metadata (the .md file is the source of truth);
            // operator can toggle enabled/disabled per path + reveal the
            // SKILL.md in Finder.
            if !fileSourceSkills.isEmpty {
                Section {
                    ForEach(fileSourceSkills, id: \.path) { fs in
                        fileSkillRow(fs)
                    }
                } header: {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.caption)
                        Text("File-source skills")
                            .font(.headline)
                        Spacer()
                        Text("\(fileSourceSkills.count) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("SKILL.md files bundled with The Bridge or installed under ~/Library/Application Support/The Bridge/skills/. Toggling here does NOT modify the .md file — it stores a per-path enable flag.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Add Skill form
            Section {
                TextField("Skill Name", text: $newSkillName)
                    .textFieldStyle(.roundedBorder)
                // V2-SKILLS: URL field with auto-detect
                TextField("URL", text: $newSkillURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: newSkillURL) { _, newValue in
                        autoDetectFromURL(newValue)
                    }
                // V2-SKILLS: UUID field (auto-populated from URL or manual entry)
                HStack {
                    TextField("UUID / Page ID", text: $newSkillPageId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    // Platform badge (read-only, auto-detected)
                    HStack(spacing: 3) {
                        Image(systemName: detectedPlatform.systemImage)
                            .font(.caption2)
                        Text(detectedPlatform.displayName)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                // W4 (3.4.1): two independent flag toggles replace the
                // 3-state picker. A new skill can be added directly into
                // the new combined state (both true) — impossible under
                // the legacy single-enum model.
                VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
                    Toggle("Show in routing discovery list", isOn: $newSkillRoutingDiscoverable)
                        .toggleStyle(.switch)
                    Toggle("Show in Commands palette", isOn: $newSkillInCommandPalette)
                        .toggleStyle(.switch)
                }

                if let error = addError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add skill") {
                    addSkill()
                }
                .disabled(newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || newSkillPageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Add a skill")
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Visibility", systemImage: "eye")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("Routing — the skill appears in the routing discovery list so agents can discover it by name without downloading the full page first.")
                    Text("Palette — the skill appears in the global Commands palette (the hot-key popover copies its page body to your clipboard).")
                    Text("Routing and Palette are independent. A skill may be in both, either, or neither. Skills not in either surface are still retrievable by name.")
                    Divider()
                        .padding(.vertical, 4)
                    Text("Skills are documents loaded at runtime when an agent requests them by name. Add the URL above to auto-detect the platform, or enter a UUID manually.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            skillsManager.reloadFromUserDefaults()
            loadFileSourceSkills()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notionBridgeSkillsStorageDidChange)) { _ in
            skillsManager.reloadFromUserDefaults()
        }
        // W4 (3.4.1): destructive delete moves behind a confirmation
        // alert so the trash button is no longer one-click fatal.
        .alert("Delete this skill?",
               isPresented: Binding(
                get: { skillPendingDeletion != nil },
                set: { if !$0 { skillPendingDeletion = nil } }
               ),
               presenting: skillPendingDeletion) { name in
            Button("Delete \(name)", role: .destructive) {
                skillsManager.removeSkill(named: name)
                skillPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                skillPendingDeletion = nil
            }
        } message: { name in
            Text("\"\(name)\" will be removed from this Notion Bridge install. The underlying Notion page is not affected. This action cannot be undone from this dialog.")
        }
    }

    // MARK: - W2 D7: File-source skill row

    @ViewBuilder
    private func fileSkillRow(_ fs: ParsedSkill) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { fileSkillEnabledMap[fs.path.path] ?? true },
                set: { newValue in
                    fileSkillEnabledMap[fs.path.path] = newValue
                    SkillsModule.setFileSkillEnabled(path: fs.path, enabled: newValue)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable \(fs.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(fs.name)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                let summary: String = {
                    if case .string(let d) = fs.frontmatter["description"] { return d }
                    return ""
                }()
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // W4 (3.4.1): single source badge — distinguishes user from
            // bundled (the section header already says "file-source").
            BridgeBadge(fs.isUserSource ? "User" : "Bundled",
                        systemImage: fs.isUserSource ? "person" : "shippingbox",
                        tone: fs.isUserSource ? .info : .neutral)

            // W4 (3.4.1): file-source rows now carry the same Routing +
            // Palette toggles as Notion-source rows — design parity per
            // operator Q3=a (unified row shape). Palette membership for
            // file-source skills is currently advisory: the palette
            // commit path requires a Notion page id (see
            // RegistrySkillsCommandProvider), so a flagged file-skill
            // will not yet appear in the hot-key popover — surfaced
            // here so the operator can stage the choice; a follow-up
            // sprint wires the file-source commit pipeline.
            HStack(spacing: BridgeSpacing.xs) {
                Toggle(isOn: Binding(
                    get: { fileSkillRoutingMap[fs.path.path] ?? false },
                    set: { newValue in
                        fileSkillRoutingMap[fs.path.path] = newValue
                        SkillsModule.setFileSkillRoutingDiscoverable(path: fs.path, value: newValue)
                    }
                )) {
                    Text("Routing").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Appear in the routing discovery list.")

                Toggle(isOn: Binding(
                    get: { fileSkillPaletteMap[fs.path.path] ?? false },
                    set: { newValue in
                        fileSkillPaletteMap[fs.path.path] = newValue
                        SkillsModule.setFileSkillInCommandPalette(path: fs.path, value: newValue)
                    }
                )) {
                    Text("Palette").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Stage membership in the Commands palette (currently advisory for file-source skills until the commit pipeline lands).")
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fs.path])
            } label: {
                Image(systemName: "folder")
                    .font(.body)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal the SKILL.md file in Finder")
            .accessibilityLabel("Reveal \(fs.name) in Finder")
        }
        .padding(.vertical, 4)
    }

    private func loadFileSourceSkills() {
        Task {
            let skills = await FilesystemSkillIndex.shared.allSkills()
            var enabledMap: [String: Bool] = [:]
            var routingMap: [String: Bool] = [:]
            var paletteMap: [String: Bool] = [:]
            for s in skills {
                enabledMap[s.path.path] = SkillsModule.isFileSkillEnabled(path: s.path)
                // W4 (3.4.1): hydrate the per-path flag mirrors. Explicit
                // toggles win; absence falls back to the frontmatter-
                // derived default for routing, false for palette.
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

    // MARK: - Skill Row

    @ViewBuilder
    private func skillRow(_ skill: SkillsManager.Skill, at index: Int) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { skill.enabled },
                set: { _ in skillsManager.toggleSkill(named: skill.name) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                // BUG-2 fix + PKT-487 F1: Click to open URL, double-click to rename
                if renamingSkillName == skill.name {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Skill Name", text: $renameText)
                            .font(.callout)
                            .fontWeight(.medium)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                commitRename(for: skill.name)
                            }
                            .onExitCommand {
                                renamingSkillName = nil
                                renameError = nil
                            }
                        if let renameError {
                            Text(renameError)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: 200)
                } else {
                    Text(skill.name)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .onTapGesture {
                            openSkillURL(skill.url ?? skill.notionPageId)
                        }
                        .onTapGesture(count: 2) {
                            commitPendingEdit()
                            renameError = nil
                            renamingSkillName = skill.name
                            renameText = skill.name
                        }
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .help("Click to open in browser. Double-click to rename.")
                }

                // PKT-487 F2: Inline URL edit — tap to edit, save on Enter/focus loss
                if editingSkillName == skill.name {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("URL", text: $editingURL)
                            .font(.caption)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                commitURLEdit(for: skill.name)
                            }
                            .onExitCommand {
                                editingSkillName = nil
                                urlValidationError = nil
                            }
                        if let urlValidationError {
                            Text(urlValidationError)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    // W4 (3.4.1): drop the always-visible UUID — surface
                    // a compact "Set URL" affordance when missing, or a
                    // small monospace 6-char tail (last 6) when set.
                    // Click still enters edit mode; the full ID lives in
                    // the field once you start editing.
                    Button {
                        commitPendingEdit()
                        urlValidationError = nil
                        editingSkillName = skill.name
                        editingURL = skill.notionPageId
                    } label: {
                        if skill.notionPageId.isEmpty {
                            Label("Set URL", systemImage: "link.badge.plus")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            let tail = String(skill.notionPageId.suffix(6))
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.caption2)
                                Text("ID …\(tail)")
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(skill.notionPageId.isEmpty
                          ? "Add a Notion page URL or UUID for this skill"
                          : "Click to edit the URL or UUID")
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // W4 (3.4.1): single platform badge — the redundant inline
            // "Notion" source badge is gone (the row's column position +
            // the section header already convey source). For platforms
            // other than Notion (manual, future), the badge surfaces the
            // platform clearly without doubling.
            BridgeBadge(skill.platform.displayName, systemImage: skill.platform.systemImage)

            // W4 (3.4.1): two independent flag toggles replace the
            // 3-state visibility picker. Routing = appears in
            // list_routing_skills. Palette = appears in the global
            // Commands palette (⌃⌥⌘C). A skill may be both — the
            // legacy enum could not express that combination.
            HStack(spacing: BridgeSpacing.xs) {
                Toggle(isOn: Binding(
                    get: { skill.routingDiscoverable },
                    set: { _ = skillsManager.setRoutingDiscoverable(named: skill.name, to: $0) }
                )) {
                    Text("Routing").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Appear in the routing discovery list so agents can find this skill by name.")

                Toggle(isOn: Binding(
                    get: { skill.inCommandPalette },
                    set: { _ = skillsManager.setInCommandPalette(named: skill.name, to: $0) }
                )) {
                    Text("Palette").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Appear in the global Commands palette hot-key (copies the page body to your clipboard).")
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer()

            // W4 (3.4.1): reorder buttons bumped from 16×14 to 24×20 +
            // wider hit area; still arrows for now (drag-handle deferred).
            VStack(spacing: 2) {
                Button {
                    commitPendingEdit()
                    skillsManager.moveSkill(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.body)
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(index == 0)
                .accessibilityLabel("Move skill up")

                Button {
                    commitPendingEdit()
                    skillsManager.moveSkill(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body)
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(index == skillsManager.skills.count - 1)
                .accessibilityLabel("Move skill down")
            }

            // W4 (3.4.1): destructive trash now opens a confirmation
            // alert instead of firing on click.
            Button(role: .destructive) {
                skillPendingDeletion = skill.name
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.8))
            .accessibilityLabel("Delete skill \(skill.name)")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions (PKT-487)

    /// Open a skill's Notion page URL in the default browser.
    private func openSkillURL(_ urlString: String) {
        let candidate: String
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            candidate = urlString
        } else if !urlString.isEmpty {
            // BUG-3 fix: Strip dashes from stored UUID — Notion URLs require 32 hex digits without dashes
            let hex = urlString.replacingOccurrences(of: "-", with: "")
            candidate = "https://www.notion.so/\(hex)"
        } else {
            return
        }
        guard let url = URL(string: candidate) else { return }
        NSWorkspace.shared.open(url)
    }

    /// BUG-2 fix: Commit the current inline rename, if any.
    private func commitRename(for skillName: String) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renameError = "Name cannot be empty."
            return
        }
        let success = skillsManager.renameSkill(named: skillName, to: trimmed)
        if success {
            renamingSkillName = nil
            renameError = nil
        } else {
            renameError = "A skill with this name already exists."
        }
    }

    /// Commit the current inline URL edit, if any.
    private func commitPendingEdit() {
        if let name = editingSkillName {
            commitURLEdit(for: name)
        }
        // Also commit pending rename
        if let name = renamingSkillName {
            commitRename(for: name)
        }
    }

    /// Save the inline URL edit for a specific skill.
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

    // MARK: - Add Skill

    // V2-SKILLS: Auto-detect platform and populate UUID from URL
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
            // Don't clear pageId — user may enter UUID manually
            detectedPlatform = SkillURLParser.detectPlatform(from: trimmed)
        }
    }

    private func addSkill() {
        addError = nil
        let name = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageId = newSkillPageId.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlValue = newSkillURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Determine platform: if URL was provided and parsed, use detected; else try Notion default
        let platform = detectedPlatform != .manual ? detectedPlatform : .notion
        let storedURL: String? = urlValue.isEmpty ? nil : urlValue

        // For Notion platform, validate UUID via NotionPageRef
        if platform == .notion {
            switch NotionPageRef.normalizedPageId(from: pageId) {
            case .failure(let err):
                addError = err.message
                return
            case .success(let normalized):
                let success = skillsManager.addSkill(name: name, notionPageId: normalized, visibility: newSkillVisibility)
                if success {
                    // W4 (3.4.1): apply the flag pair captured on the add
                    // form. The legacy `visibility:` add path uses the
                    // single-axis default; the two flag toggles now take
                    // precedence on the freshly-added skill.
                    _ = skillsManager.setRoutingDiscoverable(named: name, to: newSkillRoutingDiscoverable)
                    _ = skillsManager.setInCommandPalette(named: name, to: newSkillInCommandPalette)
                    if storedURL != nil || platform != .notion {
                        skillsManager.updateSkillExtras(named: name, url: storedURL, platform: platform)
                    }
                    resetAddForm()
                } else {
                    addError = "A skill with this name already exists."
                }
            }
        } else {
            // Non-Notion platforms: store UUID as-is
            guard !pageId.isEmpty else {
                addError = "UUID is required."
                return
            }
            let success = skillsManager.addSkill(name: name, notionPageId: pageId, visibility: newSkillVisibility)
            if success {
                _ = skillsManager.setRoutingDiscoverable(named: name, to: newSkillRoutingDiscoverable)
                _ = skillsManager.setInCommandPalette(named: name, to: newSkillInCommandPalette)
                skillsManager.updateSkillExtras(named: name, url: storedURL, platform: platform)
                resetAddForm()
            } else {
                addError = "A skill with this name already exists."
            }
        }
    }

    private func resetAddForm() {
        newSkillName = ""
        newSkillPageId = ""
        newSkillURL = ""
        newSkillVisibility = .standard
        newSkillRoutingDiscoverable = false
        newSkillInCommandPalette = false
        detectedPlatform = .manual
    }
}
