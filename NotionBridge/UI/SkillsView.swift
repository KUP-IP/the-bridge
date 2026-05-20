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
                        "Some skills have an invalid Notion page ID (not 32 hex digits). Fix the URL or ID in Settings — fetch_skill and sync will fail until corrected.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            // F11: Cross-tab dependency guard
            if fetchSkillDisabled && !skillsManager.skills.isEmpty {
                Section {
                    Label("The fetch_skill tool is disabled in Tools. Skills won\u{2019}t be available to AI clients until it\u{2019}s re-enabled.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
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
                        Text("Skills are Notion pages that AI clients can fetch at runtime via the fetch_skill MCP tool.")
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
                    Text("SKILL.md files bundled with Notion Bridge or installed under ~/Library/Application Support/Notion Bridge/skills/. Toggling here does NOT modify the .md file — it stores a per-path enable flag.")
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
                // cmd-ux W3: iterate SkillVisibility.allCases — single
                // source of truth (no hardcoded tag list); a future case
                // appears automatically with its pickerLabel.
                Picker("Visibility", selection: $newSkillVisibility) {
                    ForEach(SkillVisibility.allCases, id: \.self) { v in
                        Text(v.pickerLabel).tag(v)
                    }
                }

                if let error = addError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add Skill") {
                    addSkill()
                }
                .disabled(newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || newSkillPageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Add Skill")
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Visibility", systemImage: "eye")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("Standard — Skill text is fetched with fetch_skill when the skill is enabled. It does not appear in the lightweight discovery list (list_routing_skills).")
                    Text("Routing — The skill is listed by list_routing_skills so agents can discover it by name without downloading the full page first.")
                    Text("Command — The skill appears in the global Commands palette (the hot-key command box copies its page body to your clipboard). It is still fetchable by name via fetch_skill, but is NOT in the routing discovery list.")
                    Divider()
                        .padding(.vertical, 4)
                    Text("Skills are documents loaded at runtime via the fetch_skill MCP tool. Add the URL above to auto-detect the platform, or enter a UUID manually. Visibility only affects discovery surfaces (routing list / Commands palette); fetch_skill is name-based and works for any enabled skill regardless of visibility.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
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
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Text(fs.displayPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 3) {
                Image(systemName: "doc.text")
                    .font(.caption2)
                Text(fs.isUserSource ? "User" : "Bundled")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fs.path])
            } label: {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal SKILL.md in Finder")
        }
        .padding(.vertical, 2)
    }

    private func loadFileSourceSkills() {
        Task {
            let skills = await FilesystemSkillIndex.shared.allSkills()
            var enabledMap: [String: Bool] = [:]
            for s in skills {
                enabledMap[s.path.path] = SkillsModule.isFileSkillEnabled(path: s.path)
            }
            await MainActor.run {
                self.fileSourceSkills = skills
                self.fileSkillEnabledMap = enabledMap
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
                    Text(skill.notionPageId.isEmpty ? "No URL set" : skill.notionPageId)
                        .font(.caption)
                        .foregroundStyle(skill.notionPageId.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .onTapGesture {
                            commitPendingEdit()
                            urlValidationError = nil
                            editingSkillName = skill.name
                            editingURL = skill.notionPageId
                        }
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            // V2-SKILLS: Platform badge
            HStack(spacing: 3) {
                Image(systemName: skill.platform.systemImage)
                    .font(.caption2)
                Text(skill.platform.displayName)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // W2 D7: source badge — distinguishes Notion-page-backed
            // skills (this row) from file-source SKILL.md skills (their
            // own section above). Notion-source rows are always "Notion"
            // here because file-source skills don't live in this list.
            HStack(spacing: 3) {
                Image(systemName: "network")
                    .font(.caption2)
                Text("Notion")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // cmd-ux W3: per-row picker also iterates allCases — same
            // single source. The set: closure write-back persists via
            // SkillsManager.setVisibility (covered by a W3 unit test).
            Picker("", selection: Binding(
                get: { skill.visibility },
                set: { skillsManager.setVisibility(named: skill.name, to: $0) }
            )) {
                ForEach(SkillVisibility.allCases, id: \.self) { v in
                    Text(v.pickerLabel).tag(v)
                }
            }
            .labelsHidden()
            .frame(minWidth: 160)
            .help("Routing = list_routing_skills · Standard = fetch_skill only · Command = global Commands palette (still fetchable by name)")

            Spacer()

            // PKT-487 F3: Reorder buttons — up/down chevrons
            VStack(spacing: 0) {
                Button {
                    commitPendingEdit()
                    skillsManager.moveSkill(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2)
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(index == 0)

                Button {
                    commitPendingEdit()
                    skillsManager.moveSkill(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(index == skillsManager.skills.count - 1)
            }

            Button(role: .destructive) {
                skillsManager.removeSkill(named: skill.name)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
        }
        .padding(.vertical, 2)
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
                    // Update url/platform on the just-added skill
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
        detectedPlatform = .manual
    }
}
