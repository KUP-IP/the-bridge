// SkillsView.swift — Skills Tab in Settings (v4 "Liquid Glass, evolved").
// NotionBridge · UI
// PKT-366 F9: Skills configuration UI with add/remove/toggle.
// PKT-366 F11: Cross-tab dependency guard (fetch_skill disabled warning).
// PKT-487: Clickable names, inline URL edit, reorder, sort alphabetically.
// v3.7.2 bundle-2 redesign: twin master–detail to match the locked mockup.
// v4 redesign (PKT skills): the design's primary vertical slice — recreated
//   from design/.../skills/skills-window.jsx faithfully on the W1 token ladder
//   (BridgeTokens) + the W2 component kit (BridgeUIKit / BridgeTheme*). The
//   surface gains: emoji skill glyphs, KIND grouping (by visibility tier),
//   a SOURCE filter (Notion · Google Docs · File), a counts banner
//   (BridgeStatStrip), and the offline body-cache pattern — a peek (BridgePeek)
//   that expands into a float (BridgeFloat), a "Not stored" state, a list-level
//   "Cache all" action, plus the empty / loading / error edge states
//   (BridgeEmptyStateView / BridgeLoadingView / BridgeErrorView).
//
//   EVERY binding is preserved verbatim — SkillsManager CRUD (add / remove /
//   rename / reorder / sort), the routing / palette / enabled flags, inline URL
//   editing, the platform badge, file-source skills + their per-path toggles,
//   the add form, and the workspace cache-refresh closure (`onRefreshCache` +
//   its `cacheBusy` / `cacheMessage` / `cacheIsError` status bindings). Only the
//   view layer was restructured; the data sources + actions are unchanged.

import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Skills tab for the Settings window — twin master–detail, v4 surface.
struct SkillsView: View {
    let skillsManager: SkillsManager

    /// F11: Whether `fetch_skill` is currently disabled in the Tools tab.
    var fetchSkillDisabled: Bool = false

    // PKT-skills: skill-cache action demoted from a standalone card into the
    // list-column overflow menu. The owning SkillsSection retains the real
    // SkillsCacheWriter logic and drives these transient bindings.
    var cacheBusy: Bool = false
    var cacheMessage: String? = nil
    var cacheIsError: Bool = false
    var onRefreshCache: () -> Void = {}

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

    /// v4 source filter (mirrors `.sk-filter` — All · File · Notion · Google
    /// Docs). Drives both the list grouping and the counts banner.
    private enum SourceFilter: String, CaseIterable, Hashable {
        case all, file, notion, gdocs
        var label: String {
            switch self {
            case .all:    return "All"
            case .file:   return "File"
            case .notion: return "Notion"
            case .gdocs:  return "Google Docs"
            }
        }
    }
    @State private var sourceFilter: SourceFilter = .all

    /// v4 body-cache preview tab + expand-on-click float (the `.sk-peek` →
    /// `.sk-float` pattern). The body shown is the skill's MCP summary (the only
    /// body this install stores per-skill); expanding floats it full-height.
    private enum BodyTab: Hashable { case preview, markdown }
    @State private var bodyTab: BodyTab = .preview
    @State private var expandedBody: Bool = false
    /// File-source expand state (separate so the float can read the on-disk body).
    @State private var expandedBodyFile: String? = nil

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
    /// `false` until the async file-source index returns once. Drives the
    /// loading edge state during the genuine first-load window (when no Notion
    /// skills exist yet either, so the list would otherwise read as empty).
    @State private var filesLoaded: Bool = false

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
                    .fill(BridgeTokens.hairline)
                    .frame(width: 0.5)
                detailColumn
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v4: the expand-on-click body float, scoped over the whole page.
        .overlay { bodyFloatOverlay }
        .onAppear {
            skillsManager.reloadFromUserDefaults()
            loadFileSourceSkills()
            restoreSelectionIfNeeded()
        }
        .onChange(of: selection) { _, _ in
            // A new selection collapses any open body float + resets the tab.
            expandedBody = false
            expandedBodyFile = nil
            bodyTab = .preview
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

    // MARK: - Banners (cross-tab guards — unchanged semantics, BridgeBanner skin)

    @ViewBuilder
    private var banners: some View {
        let invalidPageSkills = skillsManager.skills.filter { !NotionPageRef.isValidStoredPageId($0.notionPageId) }
        let palettePopulation = skillsManager.skills.filter { $0.enabled && $0.inCommandPalette }.count
            + fileSourceSkills.filter { (fileSkillEnabledMap[$0.path.path] ?? true) && (fileSkillPaletteMap[$0.path.path] ?? false) }.count
        let showInvalid = !invalidPageSkills.isEmpty
        let showFetchOff = fetchSkillDisabled && !skillsManager.skills.isEmpty
        let showPaletteEmpty = !skillsManager.skills.isEmpty && palettePopulation == 0
        let cacheFailed = cacheIsError && (cacheMessage != nil) && !cacheBusy

        if showInvalid || showFetchOff || showPaletteEmpty || cacheFailed {
            VStack(spacing: 8) {
                if cacheFailed {
                    // v4: the Notion-fetch-failed guard reads as the error edge
                    // state — a .bad banner with a Retry that re-runs the real
                    // workspace cache refresh.
                    BridgeErrorView(
                        message: cacheMessage ?? "Notion fetch failed — showing cached skills. Check the credential.",
                        retryTitle: "Retry",
                        onRetry: onRefreshCache)
                }
                if showInvalid {
                    BridgeBanner(
                        signal: .warn,
                        message: "Some skills have an invalid Notion page ID (not 32 hex digits). Fix the URL or ID — these skills won\u{2019}t be retrievable by agents until corrected.")
                }
                if showFetchOff {
                    BridgeBanner(
                        signal: .warn,
                        message: "Skill retrieval is disabled in Tools. Skills won\u{2019}t be available to AI clients until you re-enable it.")
                }
                if showPaletteEmpty {
                    BridgeBanner(
                        signal: .info,
                        message: "No skills in the Commands palette yet. Flip a skill\u{2019}s Palette toggle to make it appear in the global hot-key popover. Routing is independent.")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
    }

    // MARK: - LIST COLUMN (master)

    private var listColumn: some View {
        VStack(spacing: 0) {
            // search + add + overflow (matches `.sk-toolbar`)
            HStack(spacing: 8) {
                searchField
                addButton
                listOverflowMenu
            }
            .padding(.horizontal, 14).padding(.vertical, 11)

            // counts banner + source filter (`.sk-counts`)
            countsAndFilter
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider().overlay(BridgeTokens.hairline)

            // list body — grouped by kind (visibility tier) + file-source group
            ScrollView {
                LazyVStack(spacing: 2) {
                    listContent
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }

            Divider().overlay(BridgeTokens.hairline)

            // footer: live cache message OR the index health line (`.sk-listfoot`)
            listFooter
        }
        .background(BridgeTokens.wellFill)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(BridgeTokens.fg5)
            TextField("Search skills…", text: $searchText)
                .textFieldStyle(.plain)
                .font(BridgeTokens.Typeface.base)
                .foregroundStyle(BridgeTokens.fg1)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous)
            .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.input)
    }

    /// `+` new-skill button — the accent-filled `.sk-iconbtn.on` when add-mode
    /// is active, the neutral glass control otherwise.
    private var addButton: some View {
        Button {
            commitPendingEdit()
            showAddForm = true
            selection = nil
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(showAddForm ? BridgeTokens.onAccent : BridgeTokens.fg2)
                .frame(width: 32, height: 32)
                .background(addButtonBackground)
                .clipShape(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add a new skill")
        .accessibilityLabel("Add a new skill")
    }

    @ViewBuilder
    private var addButtonBackground: some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
        if showAddForm {
            shape.fill(LinearGradient(colors: [BridgeTokens.accentStrong, BridgeTokens.accent],
                                      startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(BridgeTokens.accentBorder, lineWidth: 0.5))
        } else {
            shape.fill(BridgeTokens.glassControl)
                .overlay(shape.strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
                .bridgeBevel(BridgeTokens.bevelControl, radius: BridgeTokens.Radius.control)
        }
    }

    /// PKT-skills: list-column overflow — Sort alphabetically · Cache all (the
    /// demoted workspace cache refresh) · Refresh cache. All cache items fire
    /// the SAME real `onRefreshCache` closure the owning section drives.
    private var listOverflowMenu: some View {
        Menu {
            Button {
                commitPendingEdit()
                skillsManager.sortAlphabetically()
            } label: {
                Label("Sort by name", systemImage: "arrow.up.arrow.down")
            }
            .disabled(skillsManager.skills.isEmpty)

            Divider()

            Button {
                onRefreshCache()
            } label: {
                Label("Cache all bodies", systemImage: "externaldrive.badge.timemachine")
            }
            .disabled(cacheBusy)

            Button {
                onRefreshCache()
            } label: {
                Label("Refresh skill cache", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(cacheBusy)
        } label: {
            if cacheBusy {
                ProgressView().controlSize(.small)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(BridgeTokens.fg2)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                            .fill(BridgeTokens.glassControl)
                            .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                                .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
                            .bridgeBevel(BridgeTokens.bevelControl, radius: BridgeTokens.Radius.control))
                    .contentShape(Rectangle())
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("List options — sort, cache all, refresh skill cache")
        .accessibilityLabel("List options")
    }

    /// `.sk-counts` — a 3-tile stat strip (Total / Routing / Specialist) over the
    /// source-filter segment. Matches the design's `SK_COUNTS` (total · routing ·
    /// specialist) and `.sk-count.spec` info-tint; the kind taxonomy is the
    /// model's derived `skillKind` (routing / specialist / plain).
    private var countsAndFilter: some View {
        VStack(spacing: 9) {
            BridgeStatStrip(spacing: 7) {
                BridgeStatTile(value: "\(countsTotal)", label: "Total")
                BridgeStatTile(value: "\(countsRouting)", label: "Routing", signal: .ok)
                BridgeStatTile(value: "\(countsSpecialist)", label: "Specialist", signal: .info)
            }
            BridgeSegmented(
                selection: $sourceFilter,
                options: SourceFilter.allCases.map { ($0, $0.label) })
        }
    }

    @ViewBuilder
    private var listContent: some View {
        let groups = visibleGroups
        let files = visibleFileSkills
        if isInitialLoading {
            // The loading edge state — skeleton rows while the index resolves.
            BridgeLoadingView(rows: 6)
                .padding(.horizontal, 4).padding(.top, 12)
        } else if groups.isEmpty && files.isEmpty {
            // The empty edge state (`.sk-empty` / BridgeEmptyStateView) — no
            // skills at all vs. no matches for the current query/filter.
            if skillsManager.skills.isEmpty && fileSourceSkills.isEmpty {
                BridgeEmptyStateView(
                    systemImage: "sparkles",
                    title: "No skills yet",
                    message: "Connect Notion or drop a SKILL.md in the skills folder. Add one with the + button.") {
                    BridgeButton("Add a skill", systemImage: "plus", variant: .primary) {
                        commitPendingEdit()
                        showAddForm = true
                        selection = nil
                    }
                }
                .padding(.top, 12)
            } else {
                BridgeEmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No skills match \u{201C}\(searchText)\u{201D} in the \(sourceFilter.label.lowercased()) source.")
                    .padding(.top, 12)
            }
        } else {
            ForEach(groups, id: \.id) { group in
                groupHeader(group.label, count: group.skills.count)
                ForEach(group.skills, id: \.id) { skill in
                    skillListRow(skill)
                }
            }
            if !files.isEmpty {
                groupHeader("File-source", count: files.count)
                ForEach(files, id: \.path) { fs in
                    fileListRow(fs)
                }
            }
        }
    }

    /// `.sk-group-cap` — an uppercase kind caption + count + a trailing rule.
    private func groupHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).bridgeCap()
                .foregroundStyle(BridgeTokens.fg4)
            Text("\(count)")
                .font(BridgeTokens.Typeface.micro)
                .monospacedDigit()
                .foregroundStyle(BridgeTokens.fg5)
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
        }
        .padding(.horizontal, 7)
        .padding(.top, 11).padding(.bottom, 6)
    }

    private var listFooter: some View {
        HStack(spacing: 8) {
            if let cacheMessage, cacheBusy == false {
                if cacheIsError {
                    BridgeStatusDot(.bad, size: 7)
                } else {
                    BridgeStatusDot(.ok, size: 7)
                }
                Text(cacheMessage)
                    .font(BridgeTokens.Typeface.micro)
                    .foregroundStyle(cacheIsError ? BridgeTokens.badText : BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(cacheMessage)
            } else {
                BridgeStatusDot(.ok, size: 7)
                Text(listFooterText)
                    .font(BridgeTokens.Typeface.micro)
                    .foregroundStyle(BridgeTokens.fg4)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var listFooterText: String {
        let total = skillsManager.skills.count
        let enabled = skillsManager.enabledSkills.count
        let cached = skillsManager.skills.filter { !$0.summary.isEmpty }.count
        if total == 0 { return "No skills" }
        return "\(enabled)/\(total) enabled · \(cached) cached"
    }

    // MARK: - List rows

    /// One master row (~36px): emoji glyph (or platform-glyph fallback) · name ·
    /// cache pip · 4-state status dot. A11y label = name; a11y value = the
    /// status description. (`.sk-row`)
    private func skillListRow(_ skill: SkillsManager.Skill) -> some View {
        let isSel = selection == .skill(skill.name)
        let cached = !skill.summary.isEmpty
        return Button {
            commitPendingEdit()
            showAddForm = false
            selection = .skill(skill.name)
        } label: {
            HStack(spacing: 9) {
                skillLeadingGlyph(for: skill)
                    .frame(width: 20, alignment: .center)
                Text(skill.name)
                    .font(BridgeTokens.Typeface.base)
                    .foregroundStyle(skill.enabled ? BridgeTokens.fg1 : BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                cachePip(cached: cached)
                statusDot(for: skill)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(rowBackground(selected: isSel))
            .overlay(rowAccentBar(selected: isSel), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(skill.enabled ? 1 : 0.5)
        .accessibilityLabel(skill.name)
        .accessibilityValue(statusDescription(for: skill) + (cached ? ", cached" : ", not cached"))
        .accessibilityAddTraits(isSel ? [.isButton, .isSelected] : .isButton)
    }

    /// WS-3: leading glyph for a skill row. Renders the captured Notion EMOJI
    /// icon when present; otherwise falls back to the platform SF-Symbol glyph.
    @ViewBuilder
    private func skillLeadingGlyph(for skill: SkillsManager.Skill) -> some View {
        if let emoji = skill.icon, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: 15))
                .opacity(skill.enabled ? 1.0 : 0.45)
        } else {
            Image(systemName: skill.platform.systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(skill.enabled ? BridgeTokens.fg4 : BridgeTokens.fg5)
        }
    }

    /// `.sk-cachepip` — a tiny offline-cache indicator: emerald filled-disc when
    /// the body is stored, a faint hollow disc when not.
    private func cachePip(cached: Bool) -> some View {
        Image(systemName: cached ? "externaldrive.fill" : "externaldrive")
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(cached ? BridgeTokens.okText : BridgeTokens.fg5)
            .frame(width: 14, height: 14)
            .help(cached ? "Body cached for offline use" : "Body not stored")
    }

    private func fileListRow(_ fs: ParsedSkill) -> some View {
        let isSel = selection == .file(fs.path.path)
        let enabled = fileSkillEnabledMap[fs.path.path] ?? true
        // File-source bodies ship on disk — always "cached".
        return Button {
            commitPendingEdit()
            showAddForm = false
            selection = .file(fs.path.path)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(enabled ? BridgeTokens.fg4 : BridgeTokens.fg5)
                    .frame(width: 20, alignment: .center)
                Text(fs.name)
                    .font(BridgeTokens.Typeface.base)
                    .foregroundStyle(enabled ? BridgeTokens.fg1 : BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                cachePip(cached: true)
                Circle()
                    .fill(enabled ? BridgeTokens.ok : BridgeTokens.fg5)
                    .frame(width: 8, height: 8)
                    .shadow(color: (enabled ? BridgeTokens.ok : .clear).opacity(0.6), radius: 3)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(rowBackground(selected: isSel))
            .overlay(rowAccentBar(selected: isSel), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(fs.name)
        .accessibilityValue((fs.isUserSource ? "User file" : "Bundled") + ", " + (enabled ? "enabled" : "disabled") + ", cached")
        .accessibilityAddTraits(isSel ? [.isButton, .isSelected] : .isButton)
    }

    /// VoiceOver-readable summary of the 4-state status dot.
    private func statusDescription(for skill: SkillsManager.Skill) -> String {
        if !skill.enabled { return "Disabled" }
        if skill.routingDiscoverable { return "Enabled, routing-discoverable" }
        if skill.inCommandPalette { return "Enabled, palette only" }
        return "Enabled"
    }

    /// Status dot via the W2 atom: emerald when routing-discoverable, amber when
    /// palette-only, accent when enabled-but-neither, neutral when disabled.
    private func statusDot(for skill: SkillsManager.Skill) -> some View {
        let signal: BridgeSignal = {
            if !skill.enabled { return .neutral }
            if skill.routingDiscoverable { return .ok }
            if skill.inCommandPalette { return .warn }
            return .info
        }()
        return BridgeStatusDot(signal, size: 8)
    }

    /// Selected-row fill: the neutral raised control glass + a control bevel,
    /// matching `.sk-row.sel` (selection stays neutral; accent is reserved for
    /// the leading rail + primary actions).
    @ViewBuilder
    private func rowBackground(selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if selected {
            shape.fill(BridgeTokens.glassControl)
                .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .bridgeBevel(BridgeTokens.bevelControl, radius: 8)
        } else {
            Color.clear
        }
    }

    /// `.sk-row.sel::before` — a 2.5px accent rail on the leading edge of the
    /// selected row.
    @ViewBuilder
    private func rowAccentBar(selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(BridgeTokens.accentStrong)
                .frame(width: 2.5)
                .padding(.vertical, 8)
                .padding(.leading, 1)
        }
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
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 22, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `.sk-detail-empty` — the "pick a skill" placeholder (loading · all-empty
    /// CTA · or the select-a-skill hint).
    private var detailPlaceholder: some View {
        let allEmpty = skillsManager.skills.isEmpty && fileSourceSkills.isEmpty
        return VStack(spacing: 14) {
            if isInitialLoading {
                BridgeSpinner(large: true)
                Text("Loading skills…")
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg4)
            } else if allEmpty {
                BridgeEmptyStateView(
                    systemImage: "sparkles",
                    title: "No skills yet",
                    message: "Add a skill with the + button. Skills are documents AI clients can request by name when they need them.") {
                    BridgeButton("Add a skill", systemImage: "plus", variant: .primary) {
                        commitPendingEdit()
                        showAddForm = true
                        selection = nil
                    }
                }
            } else {
                BridgeEmptyStateView(
                    systemImage: "book.closed",
                    title: "Select a skill",
                    message: "Pick a skill from the list to see its routing metadata, triggers and cached body.")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 460)
        .padding(.top, 40)
    }

    // MARK: - Notion-source detail

    @ViewBuilder
    private func notionDetail(_ skill: SkillsManager.Skill) -> some View {
        // header: glyph avatar + name (rename) + slug/url + actions
        detailHeader(skill)

        // routing metadata grid — 4 cells, Visibility elevated
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Routing metadata")
                metadataGrid(skill)
                if !skill.notionPageId.isEmpty || skill.url != nil {
                    dependsOnRow(skill)
                }
            }
        }

        // triggers / anti-triggers (read-only flat tags)
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    BridgeCardLabel("Triggers")
                    Text("· read-only")
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg5)
                }
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

        // cache + content (peek → expand-on-click)
        bodyCacheCard(skill)

        // permissions & behavior — the design's three `.sk-perm` rows
        // (Auto-load · Cache body · Fetch on activation), each wired to a real
        // binding, plus the retained Enabled master switch (the only writer of
        // `enabled`; the design keeps a disabled state but folds the toggle).
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 0) {
                BridgeCardLabel("Permissions & behavior")
                    .padding(.bottom, 10)
                permissionToggleRow(
                    title: "Auto-load into routing context",
                    sub: "List this skill when an MCP client enumerates routing skills.",
                    isOn: Binding(
                        get: { skill.routingDiscoverable },
                        set: { _ = skillsManager.setRoutingDiscoverable(named: skill.name, to: $0) }
                    ))
                tokenDivider
                permissionToggleRow(
                    title: "Cache body for offline use",
                    sub: "Keep the full body on disk for instant, offline preview \u{0026} fetch.",
                    isOn: Binding(
                        get: { !skill.summary.isEmpty },
                        // Enabling fetches + stores the body (the workspace cache
                        // refresh — this install's per-skill cache analog). The
                        // store is the SSOT, so toggling off is a no-op here.
                        set: { newValue in if newValue && skill.summary.isEmpty { onRefreshCache() } }
                    ))
                tokenDivider
                permissionToggleRow(
                    title: "Fetch on activation",
                    sub: "Pull the latest body from the source on every invoke, via the Commands palette.",
                    isOn: Binding(
                        get: { skill.inCommandPalette },
                        set: { _ = skillsManager.setInCommandPalette(named: skill.name, to: $0) }
                    ))
                tokenDivider
                permissionToggleRow(
                    title: "Enabled",
                    sub: "When off, the skill is hidden from every surface and is not retrievable by name.",
                    isOn: Binding(
                        get: { skill.enabled },
                        set: { _ in skillsManager.toggleSkill(named: skill.name) }
                    ))
            }
        }
    }

    private func detailHeader(_ skill: SkillsManager.Skill) -> some View {
        HStack(alignment: .top, spacing: 12) {
            glyphAvatar(for: skill, dimmed: !skill.enabled)

            VStack(alignment: .leading, spacing: 4) {
                // name + rename + visibility badge
                if renamingSkillName == skill.name {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Skill name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .font(BridgeTokens.Typeface.detail)
                            .frame(maxWidth: 280)
                            .onSubmit { commitRename(for: skill.name) }
                            .onExitCommand { renamingSkillName = nil; renameError = nil }
                        if let renameError {
                            Text(renameError).font(BridgeTokens.Typeface.meta).foregroundStyle(BridgeTokens.badText)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(BridgeTokens.Typeface.detail)
                            .tracking(BridgeTokens.Typeface.trackTight)
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
                                .foregroundStyle(BridgeTokens.fg5)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Rename")
                        .accessibilityLabel("Rename skill")
                        visibilityBadge(skill)
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

    /// `.sk-dhead` glyph avatar — a raised-glass disc holding the emoji icon, or
    /// the platform glyph fallback.
    @ViewBuilder
    private func glyphAvatar(for skill: SkillsManager.Skill, dimmed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack {
            BridgeTokens.glassRaise.paint(in: shape)
            shape.strokeBorder(BridgeTokens.edgeRaise, lineWidth: 0.5)
            if let emoji = skill.icon, !emoji.isEmpty {
                Text(emoji).font(.system(size: 19))
            } else {
                Image(systemName: skill.platform.systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(BridgeTokens.fg3)
            }
        }
        .frame(width: 32, height: 32)
        .bridgeBevel(BridgeTokens.bevelRaise, radius: 9)
        .opacity(dimmed ? 0.55 : 1)
    }

    /// File-source avatar (no emoji) — same disc, doc glyph.
    private func fileGlyphAvatar(dimmed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack {
            BridgeTokens.glassRaise.paint(in: shape)
            shape.strokeBorder(BridgeTokens.edgeRaise, lineWidth: 0.5)
            Image(systemName: "doc.text")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(BridgeTokens.fg3)
        }
        .frame(width: 32, height: 32)
        .bridgeBevel(BridgeTokens.bevelRaise, radius: 9)
        .opacity(dimmed ? 0.55 : 1)
    }

    /// The visibility tier badge next to the name (`.badge` — matches the
    /// design's `SK_DOT`: routing=ok "Routing-discoverable", palette=warn
    /// "Palette-only", enabled=info "Enabled", disabled=neutral).
    private func visibilityBadge(_ skill: SkillsManager.Skill) -> some View {
        let (label, tone): (String, BridgeBadge.Tone) = {
            if !skill.enabled { return ("Disabled", .neutral) }
            if skill.routingDiscoverable { return ("Routing-discoverable", .ok) }
            if skill.inCommandPalette { return ("Palette-only", .warn) }
            return ("Enabled", .info)
        }()
        return BridgeBadge(label, tone: tone, showsDot: true)
    }

    @ViewBuilder
    private func idRow(_ skill: SkillsManager.Skill) -> some View {
        if editingSkillName == skill.name {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Notion URL or UUID", text: $editingURL)
                    .textFieldStyle(.roundedBorder)
                    .font(BridgeTokens.Typeface.mono)
                    .frame(maxWidth: 320)
                    .onSubmit { commitURLEdit(for: skill.name) }
                    .onExitCommand { editingSkillName = nil; urlValidationError = nil }
                if let urlValidationError {
                    Text(urlValidationError).font(BridgeTokens.Typeface.meta).foregroundStyle(BridgeTokens.badText)
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
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.warnText)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "link").font(.system(size: 11))
                            Text("ID …\(String(skill.notionPageId.suffix(6)))")
                                .font(BridgeTokens.Typeface.mono)
                        }
                        .foregroundStyle(BridgeTokens.fg3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(skill.notionPageId.isEmpty ? "Set Notion page URL" : "Edit Notion page ID")
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
                _ = skillsManager.moveSkill(from: index, to: index - 1)
            }
            iconButton("chevron.down", help: "Move down",
                       disabled: index == skillsManager.skills.count - 1) {
                commitPendingEdit()
                _ = skillsManager.moveSkill(from: index, to: index + 1)
            }
            iconButton("trash", help: "Delete skill", danger: true) {
                skillPendingDeletion = skill.name
            }
        }
    }

    /// PKT-skills: 4 non-redundant cells; the synthesized Visibility value is
    /// elevated (`.sk-meta.key`).
    private func metadataGrid(_ skill: SkillsManager.Skill) -> some View {
        let cells: [(String, String, Bool)] = [
            ("Kind", kindLabel(skill), false),
            ("Visibility", visibilityLabel(skill), true),
            ("Source", skill.platform.displayName, false),
            ("Page", skill.notionPageId.isEmpty ? "—" : "…\(String(skill.notionPageId.suffix(6)))", false),
        ]
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
            spacing: 8
        ) {
            ForEach(cells, id: \.0) { cap, val, key in
                metaCell(cap: cap, val: val, key: key)
            }
        }
    }

    /// `.sk-meta` inset cell; `key` elevates it with an accent tint (Visibility).
    private func metaCell(cap: String, val: String, key: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Text(cap).bridgeCap()
                .foregroundStyle(key ? BridgeTokens.infoText : BridgeTokens.fg4)
            Text(val)
                .font(BridgeTokens.Typeface.meta.weight(.semibold))
                .foregroundStyle(key ? BridgeTokens.infoText : BridgeTokens.fg1)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(val)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(
            key
            ? AnyView(shape.fill(BridgeTokens.accent.opacity(0.12))
                .overlay(shape.strokeBorder(BridgeTokens.accentBorder, lineWidth: 0.5)))
            : AnyView(shape.fill(BridgeTokens.wellFill)
                .overlay(shape.strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
                .bridgeBevel(BridgeTokens.bevelInset, radius: 9))
        )
    }

    private func visibilityLabel(_ skill: SkillsManager.Skill) -> String {
        switch (skill.routingDiscoverable, skill.inCommandPalette) {
        case (true, true):   return "Both"
        case (true, false):  return "Routing"
        case (false, true):  return "Palette"
        case (false, false): return "Fetch-only"
        }
    }

    /// The design's `Kind` meta value, from the model's derived `skillKind`
    /// (Routing / Specialist / Plain) — consistent with the list grouping + the
    /// Specialist count tile.
    private func kindLabel(_ skill: SkillsManager.Skill) -> String {
        switch skill.skillKind {
        case .routing:    return "Routing"
        case .specialist: return "Specialist"
        case .plain:      return "Plain"
        }
    }

    /// `.sk-deps` — a "Depends on" row of deep-link chips (Notion credential +
    /// the page link) using the W2 `BridgeDepLink`.
    private func dependsOnRow(_ skill: SkillsManager.Skill) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            Text("DEPENDS ON")
                .font(BridgeTokens.Typeface.micro.weight(.semibold))
                .tracking(BridgeTokens.Typeface.trackCap)
                .foregroundStyle(BridgeTokens.fg5)
                .padding(.trailing, 2)
            if skill.platform == .notion {
                BridgeDepLink("Notion credential") { openSkillURL("https://www.notion.so") }
            }
            if skill.platform == .googleDocs {
                BridgeDepLink("Google credential") { openSkillURL("https://docs.google.com") }
            }
            if !(skill.url ?? skill.notionPageId).isEmpty {
                BridgeDepLink("Open page") { openSkillURL(skill.url ?? skill.notionPageId) }
            }
        }
    }

    // MARK: - Body cache card (peek → expand · Not-stored · refresh)

    /// `.sk-content-card` — the offline body-cache surface. When the skill body
    /// (its MCP summary) is stored, a `BridgePeek` previews it (Preview /
    /// Markdown tabs) and expands into a `BridgeFloat`; when empty, the
    /// "Not stored" state offers a Cache-now (which runs the real workspace
    /// cache refresh). The transient `cacheBusy` flag drives the caching look.
    @ViewBuilder
    private func bodyCacheCard(_ skill: SkillsManager.Skill) -> some View {
        let cached = !skill.summary.isEmpty
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 11) {
                // cache bar: state on the left, tabs + refresh on the right
                HStack(spacing: 9) {
                    if cacheBusy {
                        HStack(spacing: 6) {
                            BridgeSpinner()
                            Text("Caching…")
                                .font(BridgeTokens.Typeface.sub.weight(.medium))
                                .foregroundStyle(BridgeTokens.fg3)
                        }
                    } else if cached {
                        HStack(spacing: 6) {
                            Image(systemName: "externaldrive.fill.badge.checkmark")
                                .font(.system(size: 12))
                                .foregroundStyle(BridgeTokens.okText)
                            Text("Cached")
                                .font(BridgeTokens.Typeface.sub.weight(.medium))
                                .foregroundStyle(BridgeTokens.fg2)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "externaldrive")
                                .font(.system(size: 12))
                                .foregroundStyle(BridgeTokens.fg5)
                            Text("Not stored")
                                .font(BridgeTokens.Typeface.sub.weight(.medium))
                                .foregroundStyle(BridgeTokens.fg3)
                        }
                    }
                    Spacer(minLength: 8)
                    if cached {
                        bodyTabSegmented
                        BridgeButton("Refresh", systemImage: "arrow.triangle.2.circlepath",
                                     variant: .default, isEnabled: !cacheBusy) {
                            onRefreshCache()
                        }
                    }
                }

                if cached {
                    // peek → float
                    BridgePeek(maxHeight: 132, onExpand: { expandedBody = true }) {
                        bodyContentView(skill.summary)
                    }
                } else {
                    notStoredWell
                }
            }
        }
    }

    /// `.sk-uncached` — the centered "Body not cached" well with a Cache-now CTA
    /// (runs the workspace cache refresh). Shows the spinner while caching.
    private var notStoredWell: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(spacing: 11) {
            if cacheBusy {
                BridgeSpinner(large: true)
                Text("Fetching & storing bodies…")
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg2)
            } else {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(BridgeTokens.fg5)
                Text("Body not cached")
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg2)
                Text("Fetch the body once and keep it for instant, offline preview. Cache now re-pulls every skill body from its source.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                BridgeButton("Cache now", systemImage: "arrow.triangle.2.circlepath",
                             variant: .primary, isEnabled: !cacheBusy) {
                    onRefreshCache()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26).padding(.horizontal, 18)
        .background(
            shape.fill(BridgeTokens.wellFillDeep)
                .overlay(shape.strokeBorder(BridgeTokens.hairlineStrong,
                                            style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))))
    }

    /// The shared Preview / Markdown tab control for the body peek + float.
    private var bodyTabSegmented: some View {
        BridgeSegmented(
            selection: $bodyTab,
            options: [(BodyTab.preview, "Preview"), (BodyTab.markdown, "Markdown")])
            .fixedSize()
    }

    /// The body renderer for the peek / float — Preview (rendered markdown via
    /// the W2 `BridgeMarkdown`) or Markdown (raw mono).
    @ViewBuilder
    private func bodyContentView(_ md: String) -> some View {
        if bodyTab == .preview {
            BridgeMarkdown(md)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(md)
                .font(BridgeTokens.Typeface.mono)
                .foregroundStyle(BridgeTokens.fg2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The expand-on-click overlay (`.sk-scrim` + `.sk-float`) — the
    /// currently-selected skill's stored body floated full-height. Handles both
    /// the Notion case (body = summary) and the file-source case (body = on-disk
    /// SKILL.md body).
    @ViewBuilder
    private var bodyFloatOverlay: some View {
        if expandedBody,
           case .skill(let name) = selection,
           let skill = skillsManager.skill(named: name),
           !skill.summary.isEmpty {
            bodyFloat(name: skill.name,
                      glyph: AnyView(glyphAvatar(for: skill, dimmed: false).frame(width: 24, height: 24)),
                      body: skill.summary,
                      onDismiss: { expandedBody = false })
        } else if let path = expandedBodyFile,
                  let fs = fileSourceSkills.first(where: { $0.path.path == path }) {
            bodyFloat(name: fs.name,
                      glyph: AnyView(fileGlyphAvatar(dimmed: false).frame(width: 24, height: 24)),
                      body: fileBody(fs),
                      onDismiss: { expandedBodyFile = nil })
        }
    }

    /// The on-disk SKILL.md body, falling back to the frontmatter description.
    private func fileBody(_ fs: ParsedSkill) -> String {
        if !fs.body.isEmpty { return fs.body }
        if case .string(let d) = fs.frontmatter["description"] { return d }
        return ""
    }

    /// Shared `.sk-float` builder for both source kinds.
    private func bodyFloat(name: String, glyph: AnyView, body: String, onDismiss: @escaping () -> Void) -> some View {
        BridgeFloat(onDismiss: onDismiss) {
            glyph
            Text(name)
                .font(BridgeTokens.Typeface.name)
                .foregroundStyle(BridgeTokens.fg1)
            bodyTabSegmented
            Text("read-only · cached body")
                .font(BridgeTokens.Typeface.micro)
                .foregroundStyle(BridgeTokens.fg5)
            Spacer(minLength: 8)
            BridgeButton("Close", variant: .default, action: onDismiss)
        } body: {
            bodyContentView(body)
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
        HStack(alignment: .top, spacing: 12) {
            fileGlyphAvatar(dimmed: !enabled)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(fs.name)
                        .font(BridgeTokens.Typeface.detail)
                        .tracking(BridgeTokens.Typeface.trackTight)
                        .foregroundStyle(BridgeTokens.fg1)
                        .lineLimit(1)
                    BridgeBadge(fs.isUserSource ? "User file" : "Bundled",
                                systemImage: fs.isUserSource ? "person" : "shippingbox",
                                tone: fs.isUserSource ? .info : .neutral)
                }
                Text(fs.displayPath)
                    .font(BridgeTokens.Typeface.mono)
                    .foregroundStyle(BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            iconButton("folder", help: "Reveal SKILL.md in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fs.path])
            }
        }

        // metadata: source + status + path
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("File metadata")
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                    spacing: 8
                ) {
                    metaCell(cap: "Source", val: fs.isUserSource ? "User dir" : "Bundled")
                    metaCell(cap: "Status", val: enabled ? "Enabled" : "Disabled")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("PATH").bridgeCap()
                        .foregroundStyle(BridgeTokens.fg4)
                    Text(fs.displayPath)
                        .font(BridgeTokens.Typeface.mono)
                        .foregroundStyle(BridgeTokens.fg3)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)
            }
        }

        // body preview (the on-disk body is always available — peek → float)
        bodyCacheCardForFile(fs, summary: summary)

        // permission toggles (file-source — persist per path). The design's
        // three `.sk-perm` rows (Auto-load · Cache body · Fetch on activation),
        // plus the retained Enabled per-path flag (wiring preserved).
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 0) {
                BridgeCardLabel("Permissions & behavior")
                    .padding(.bottom, 10)
                permissionToggleRow(
                    title: "Auto-load into routing context",
                    sub: "List this skill when an MCP client enumerates routing skills.",
                    isOn: Binding(
                        get: { fileSkillRoutingMap[fs.path.path] ?? false },
                        set: { v in
                            fileSkillRoutingMap[fs.path.path] = v
                            SkillsModule.setFileSkillRoutingDiscoverable(path: fs.path, value: v)
                        }
                    ))
                tokenDivider
                permissionToggleRow(
                    title: "Cache body for offline use",
                    sub: "Keep the full body on disk for instant, offline preview \u{0026} fetch.",
                    // File-source bodies always ship on disk — the body is
                    // bundled, so this reads on and is not user-evictable.
                    isOn: .constant(true),
                    isEnabled: false)
                tokenDivider
                permissionToggleRow(
                    title: "Fetch on activation",
                    sub: "Pull the latest body from the source on every invoke, via the Commands palette.",
                    isOn: Binding(
                        get: { fileSkillPaletteMap[fs.path.path] ?? false },
                        set: { v in
                            fileSkillPaletteMap[fs.path.path] = v
                            SkillsModule.setFileSkillInCommandPalette(path: fs.path, value: v)
                        }
                    ))
                tokenDivider
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
            }
        }
    }

    /// File-source body card — the body is on disk, so it always shows a peek of
    /// the SKILL.md body (summary fallback to the frontmatter description).
    @ViewBuilder
    private func bodyCacheCardForFile(_ fs: ParsedSkill, summary: String) -> some View {
        let body = !fs.body.isEmpty ? fs.body : summary
        if !body.isEmpty {
            BridgeGlassCard {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 9) {
                        HStack(spacing: 6) {
                            Image(systemName: "externaldrive.fill.badge.checkmark")
                                .font(.system(size: 12))
                                .foregroundStyle(BridgeTokens.okText)
                            Text("Bundled body")
                                .font(BridgeTokens.Typeface.sub.weight(.medium))
                                .foregroundStyle(BridgeTokens.fg2)
                        }
                        Spacer(minLength: 8)
                        bodyTabSegmented
                    }
                    BridgePeek(maxHeight: 132, onExpand: { expandedBodyFile = fs.path.path }) {
                        bodyContentView(body)
                    }
                }
            }
        }
    }

    // MARK: - Add-skill form (detail pane)

    private var addSkillForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                addFormGlyph
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a skill")
                        .font(BridgeTokens.Typeface.detail)
                        .tracking(BridgeTokens.Typeface.trackTight)
                        .foregroundStyle(BridgeTokens.fg1)
                    Text("Add a Notion or Google Docs URL to auto-detect the platform, or enter a UUID manually.")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                iconButton("xmark", help: "Cancel") {
                    showAddForm = false
                    resetAddForm()
                }
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
                            .font(BridgeTokens.Typeface.sub)
                            .foregroundStyle(BridgeTokens.badText)
                    }

                    HStack {
                        Spacer()
                        BridgeButton("Add skill", variant: .primary,
                                     isEnabled: !(newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                  || newSkillPageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) {
                            addSkill()
                        }
                    }
                }
            }

            BridgeGlassCard {
                VStack(alignment: .leading, spacing: 7) {
                    BridgeCardLabel("How visibility works")
                    helpLine("Routing", "appears in the routing discovery list so agents can find it by name.")
                    helpLine("Palette", "appears in the global Commands palette hot-key popover.")
                    Text("Routing and Palette are independent — a skill may be in both, either, or neither. Skills in neither surface are still retrievable by name.")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Accent-tinted glyph disc for the add-form header.
    private var addFormGlyph: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack {
            shape.fill(BridgeTokens.accent.opacity(0.16))
            shape.strokeBorder(BridgeTokens.accentBorder, lineWidth: 0.5)
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BridgeTokens.infoText)
        }
        .frame(width: 32, height: 32)
    }

    private func formField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).bridgeCap()
                .foregroundStyle(BridgeTokens.fg4)
            content()
        }
    }

    private func helpLine(_ term: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(term)
                .font(BridgeTokens.Typeface.sub.weight(.semibold))
                .foregroundStyle(BridgeTokens.accentLink)
            Text("— \(desc)")
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg3)
        }
    }

    // MARK: - Shared detail bits

    /// PKT-skills: read-only trigger / anti-trigger tags. Flat low-radius wells
    /// (NOT the interactive `.chip` pill) so static routing data does not read
    /// as tappable. (`.sk-trig`)
    private func chipFlow(_ phrases: [String], anti: Bool) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(phrases, id: \.self) { p in
                Text(p)
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(anti ? BridgeTokens.badText : BridgeTokens.fg3)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(triggerTagBackground(anti: anti))
                    .accessibilityLabel((anti ? "Anti-trigger: " : "Trigger: ") + p)
            }
        }
    }

    @ViewBuilder
    private func triggerTagBackground(anti: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if anti {
            shape.fill(BridgeTokens.bad.opacity(0.10))
                .overlay(shape.strokeBorder(BridgeTokens.bad.opacity(0.22), lineWidth: 0.5))
        } else {
            shape.fill(BridgeTokens.wellFill)
                .overlay(shape.strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(BridgeTokens.Typeface.sub)
            .foregroundStyle(BridgeTokens.fg4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var tokenDivider: some View {
        Rectangle()
            .fill(BridgeTokens.hairlineFaint)
            .frame(height: 0.5)
            .padding(.vertical, 10)
    }

    /// `.sk-perm` — a permission row: title + sub on the left, the W2
    /// `BridgeToggle` on the right. `isEnabled: false` renders a non-interactive
    /// row (e.g. a bundled file body that is always cached and not evictable).
    private func permissionToggleRow(title: String, sub: String, isOn: Binding<Bool>, isEnabled: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg1)
                Text(sub)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            BridgeToggle(isOn: isOn)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)
                .accessibilityLabel(title)
                .accessibilityHint(sub)
        }
        .padding(.vertical, 10)
    }

    /// Small neutral-glass icon button (`.sk-iconbtn` / `.sk-rename` / actions).
    private func iconButton(_ systemImage: String, help: String, disabled: Bool = false, danger: Bool = false, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(danger ? BridgeTokens.badText : BridgeTokens.fg3)
                .frame(width: 30, height: 30)
                .background(
                    shape.fill(BridgeTokens.glassControl)
                        .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                        .bridgeBevel(BridgeTokens.bevelControl, radius: BridgeTokens.Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
    }

    // MARK: - Counts (real visibility taxonomy)

    /// Counts honor the active source filter so the banner reflects what's shown.
    private var countableSkills: [SkillsManager.Skill] {
        switch sourceFilter {
        case .all:    return skillsManager.skills
        case .notion: return skillsManager.skills.filter { $0.platform == .notion }
        case .gdocs:  return skillsManager.skills.filter { $0.platform == .googleDocs }
        case .file:   return []   // file-source skills are not SkillsManager.Skill
        }
    }
    private var countsTotal: Int {
        countableSkills.count + (sourceFilter == .all || sourceFilter == .file ? fileSourceSkills.count : 0)
    }
    private var countsRouting: Int {
        countableSkills.filter { $0.enabled && $0.routingDiscoverable }.count
            + ((sourceFilter == .all || sourceFilter == .file)
               ? fileSourceSkills.filter { (fileSkillEnabledMap[$0.path.path] ?? true) && (fileSkillRoutingMap[$0.path.path] ?? false) }.count
               : 0)
    }
    /// `.sk-count.spec` — specialists per the model's derived `skillKind`
    /// (`.specialist` = curated/palette-pinned but NOT routing-discoverable).
    /// File-source skills are `plain` by the design taxonomy, so they do not
    /// add to the specialist count.
    private var countsSpecialist: Int {
        countableSkills.filter { $0.enabled && $0.skillKind == .specialist }.count
    }

    // MARK: - Filtering + grouping

    /// Notion / GDocs skills after the search query + source filter.
    private var filteredSkills: [SkillsManager.Skill] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return skillsManager.skills.filter { skill in
            let matchesQuery = q.isEmpty
                || skill.name.lowercased().contains(q)
                || skill.summary.lowercased().contains(q)
            let matchesSource: Bool = {
                switch sourceFilter {
                case .all:    return true
                case .notion: return skill.platform == .notion
                case .gdocs:  return skill.platform == .googleDocs
                case .file:   return false
                }
            }()
            return matchesQuery && matchesSource
        }
    }

    /// File-source skills after the search query + source filter.
    private var visibleFileSkills: [ParsedSkill] {
        guard sourceFilter == .all || sourceFilter == .file else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return fileSourceSkills }
        return fileSourceSkills.filter { $0.name.lowercased().contains(q) }
    }

    /// Kind grouping — the design's `SK_KINDS` taxonomy (Routing & orchestrators
    /// · Specialists · Plain skills), driven by the model's derived `skillKind`
    /// (`.routing` = routing-discoverable · `.specialist` = palette-pinned but
    /// not routing · `.plain` = neither). (`.sk-group-cap`)
    private struct SkillGroup { let id: String; let label: String; let skills: [SkillsManager.Skill] }
    private var visibleGroups: [SkillGroup] {
        let all = filteredSkills
        let routing    = all.filter { $0.skillKind == .routing }
        let specialist = all.filter { $0.skillKind == .specialist }
        let plain      = all.filter { $0.skillKind == .plain }
        return [
            SkillGroup(id: "routing",    label: "Routing & orchestrators", skills: routing),
            SkillGroup(id: "specialist", label: "Specialists",             skills: specialist),
            SkillGroup(id: "plain",      label: "Plain skills",            skills: plain),
        ].filter { !$0.skills.isEmpty }
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
                self.filesLoaded = true
            }
        }
    }

    /// The genuine first-load window: the async file index hasn't returned yet
    /// AND there are no Notion skills to show, so the list would read as empty.
    private var isInitialLoading: Bool {
        !filesLoaded && skillsManager.skills.isEmpty
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
            if skillsManager.updateSkillURL(named: skillName, newPageId: normalized) {
                // WS-3: the page binding changed — re-capture its emoji icon.
                captureNotionIcon(forSkill: skillName, pageId: normalized)
            }
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
                        _ = skillsManager.updateSkillExtras(named: name, url: storedURL, platform: platform)
                    }
                    // WS-3: capture the Notion page EMOJI icon in the
                    // background (best-effort; never blocks the add).
                    captureNotionIcon(forSkill: name, pageId: normalized)
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
                _ = skillsManager.updateSkillExtras(named: name, url: storedURL, platform: platform)
                finishAdd(selecting: name)
            } else {
                addError = "A skill with this name already exists."
            }
        }
    }

    /// WS-3: Best-effort background fetch of a Notion page's EMOJI icon, stored
    /// on the skill when present. Runs detached; failures are swallowed.
    private func captureNotionIcon(forSkill name: String, pageId: String) {
        let manager = skillsManager
        Task.detached(priority: .utility) {
            guard let client = try? NotionClient(),
                  let data = try? await client.getPage(pageId: pageId),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let emoji = NotionModule.extractIconEmoji(from: json) else {
                return
            }
            await MainActor.run {
                _ = manager.setIcon(named: name, to: emoji)
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
/// (the `.sk-trigs` flex-wrap idiom from skills.css).
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
