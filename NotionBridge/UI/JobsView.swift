// JobsView.swift — Settings > Jobs · shared row / detail / sheet components.
// NotionBridge · UI · v3.7.3 redesign
//
// v3.7.3 redesign: the Jobs page is now owned end-to-end by JobsSection (the
// locked Liquid-Glass mockup — hero stat tiles, failing-job alert banner,
// glass scheduled-job rows, expandable run-log). This file no longer renders
// the page chrome; it hosts the reusable pieces JobsSection composes:
//   • JobGlassRow      — one scheduled-job row (icon tile, name, schedule,
//                        next-run, status dot/badge, pause/resume + run icons)
//   • JobDetailView    — the inline-expand editor (name/schedule/actions/options
//                        + Run/Duplicate/Pause/Delete/Save) — bindings verbatim
//   • NewJobSheet      — +New job sheet (create)
//   • ImportSheet      — paste/load a jobs export
//
// EVERY store binding and action is preserved verbatim from the prior
// JobsView/JobCard implementation — only the presentation moved to glass.
// The public `JobsView` shim renders JobsSection so any stray caller still
// resolves to the redesigned page.

import SwiftUI
import AppKit

// MARK: - Public shim

/// Back-compat entry point. The Jobs page is rendered by ``JobsSection``;
/// this thin wrapper keeps `JobsView()` resolving to the redesigned page.
public struct JobsView: View {
    public init() {}
    public var body: some View { JobsSection() }
}

// MARK: - Scheduled-job row (glass)

/// One scheduled-job row in the "Scheduled jobs" card — mirrors `.jb-row`
/// from the locked mockup: an accent icon tile, name + mono cron + tool
/// detail, an optional inline failing-credential banner, a right-aligned
/// next-run column, a status badge, and pause/resume + run icon-buttons.
/// Tapping the body toggles the inline detail editor.
struct JobGlassRow: View {
    let job: JobRecord
    /// Most-recent execution for this job, if any — drives the failing banner
    /// + run-now ("retry") affordance. Derived by JobsSection from the store.
    let lastExecution: ExecutionRecord?
    let isExpanded: Bool
    let onToggle: () -> Void
    let onChanged: () -> Void

    @State private var busy = false

    private var isFailing: Bool {
        job.status == .active && lastExecution?.status == .failure
    }

    private var tone: Tone {
        if isFailing { return .bad }
        return job.status == .active ? .ok : .warn
    }

    private enum Tone { case ok, warn, bad
        var dot: Color {
            switch self { case .ok: return BridgeTokens.ok
                          case .warn: return BridgeTokens.warn
                          case .bad: return BridgeTokens.bad }
        }
        var badge: String {
            switch self { case .ok: return "Active"; case .warn: return "Paused"; case .bad: return "Failing" }
        }
        var badgeBG: Color {
            switch self { case .ok: return BridgeTokens.ok.opacity(0.16)
                          case .warn: return BridgeTokens.warn.opacity(0.16)
                          case .bad: return BridgeTokens.bad.opacity(0.14) }
        }
        var badgeFG: Color {
            switch self { case .ok: return BridgeTokens.okText
                          case .warn: return BridgeTokens.warnText
                          case .bad: return BridgeTokens.badText }
        }
        var iconTint: Color {
            switch self { case .ok: return BridgeTokens.okText
                          case .warn: return BridgeTokens.warnText
                          case .bad: return BridgeTokens.badText }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            rowHeader
            if isExpanded {
                Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5).padding(.top, 10)
                JobDetailView(job: job, onChanged: onChanged)
                    .padding(.top, 6)
            }
        }
    }

    private var rowHeader: some View {
        HStack(alignment: .top, spacing: 11) {
            iconTile
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg1)
                    .lineLimit(1)
                subline
                if isFailing { failingBanner }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(nextRunText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg3)
                    .monospacedDigit()
                statusBadge
            }
            actions
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BridgeTokens.fg5)
                .frame(width: 16)
                .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BridgeTokens.chipFill)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            Image(systemName: jobGlyph)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tone.iconTint)
        }
        .frame(width: 30, height: 30)
        .padding(.top, 1)
    }

    private var subline: some View {
        HStack(spacing: 5) {
            Text(job.schedule)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(BridgeTokens.fg2)
            Text("·").foregroundStyle(BridgeTokens.fg5)
            Text(detailText)
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg4)
                .lineLimit(1)
        }
    }

    private var failingBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(BridgeTokens.badText)
            Text(lastExecution?.errorMessage ?? "Last run failed — check the job log.")
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.badText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BridgeTokens.bad.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.bad.opacity(0.26), lineWidth: 0.5))
        .padding(.top, 6)
    }

    private var statusBadge: some View {
        Text(tone.badge)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.badgeFG)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(tone.badgeBG, in: Capsule())
            .overlay(Capsule().strokeBorder(tone.dot.opacity(0.30), lineWidth: 0.5))
    }

    private var actions: some View {
        HStack(spacing: 3) {
            if job.status == .active {
                iconButton("pause.fill", help: "Pause") { await pause() }
            } else {
                iconButton("play.fill", help: "Resume") { await resume() }
            }
            iconButton("arrow.clockwise", help: "Run now") { await runNow() }
            Menu {
                Button { Task { await runNow() } } label: { Label("Run Now", systemImage: "play.fill") }
                Button {
                    Task {
                        _ = try? await JobsManager.shared.duplicateJobTool(args: .object(["id": .string(job.id)]))
                        onChanged()
                    }
                } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.id, forType: .string)
                } label: { Label("Copy ID", systemImage: "doc.on.doc") }
                Divider()
                Button(role: .destructive) {
                    Task {
                        _ = try? await JobsManager.shared.deleteJob(args: .object(["id": .string(job.id)]))
                        onChanged()
                    }
                } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg3)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.top, 1)
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () async -> Void) -> some View {
        Button {
            guard !busy else { return }
            Task { busy = true; await action(); busy = false }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BridgeTokens.fg3)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(busy)
    }

    // MARK: row actions (bindings preserved)

    private func pause() async {
        _ = try? await JobsManager.shared.pauseJob(args: .object(["id": .string(job.id)]))
        onChanged()
    }
    private func resume() async {
        _ = try? await JobsManager.shared.resumeJob(args: .object(["id": .string(job.id)]))
        onChanged()
    }
    private func runNow() async {
        _ = try? await JobsManager.shared.runNowTool(args: .object(["id": .string(job.id)]))
        onChanged()
    }

    // MARK: derived text

    private var detailText: String {
        if let primary = job.actionChain.first {
            let extra = job.actionChain.count > 1 ? " +\(job.actionChain.count - 1)" : ""
            return primary.tool + extra
        }
        return CronHumanizer.describe(job.schedule) ?? "no actions"
    }

    /// Compact, human next-run hint. Paused jobs read "paused"; failing jobs
    /// read "retrying…"; otherwise the humanized cadence (or raw schedule).
    private var nextRunText: String {
        if job.status == .paused { return "paused" }
        if isFailing { return "retrying…" }
        return CronHumanizer.describe(job.schedule) ?? "scheduled"
    }

    /// A stable per-job SF Symbol so rows are visually distinguishable, keyed
    /// off the primary tool family. Purely cosmetic.
    private var jobGlyph: String {
        let tool = job.actionChain.first?.tool.lowercased() ?? ""
        if tool.contains("stripe") || tool.contains("invoice") || tool.contains("payment") { return "creditcard" }
        if tool.contains("notion") { return "doc.text" }
        if tool.contains("credential") || tool.contains("token") { return "key" }
        if tool.contains("strava") || tool.contains("fetch") || tool.contains("http") { return "arrow.triangle.2.circlepath" }
        if tool.contains("shell") || tool.contains("script") || tool.contains("exec") { return "terminal" }
        if tool.contains("mail") || tool.contains("message") { return "envelope" }
        return "bolt"
    }
}

// MARK: - New Job sheet

struct NewJobSheet: View {
    let onCancel: () -> Void
    let onCreate: () async -> Void

    @State private var name = ""
    @State private var schedule = "0 9 * * 1-5"
    @State private var actionsJSON = """
[
  {
    "tool": "shell_exec",
    "arguments": { "command": "echo hello" }
  }
]
"""
    @State private var skipOnBattery = false
    @State private var scheduleError: String?
    @State private var actionsError: String?
    @State private var creating = false
    @State private var errorMsg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Scheduled Job").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                TextField("Schedule (cron)", text: $schedule)
                    .font(.body.monospaced())
                    .onChange(of: schedule) { _, v in validateSchedule(v) }
                if let err = scheduleError {
                    Text(err).font(.caption).foregroundStyle(BridgeTokens.bad)
                } else {
                    Text((CronHumanizer.describe(schedule) ?? schedule)).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Skip when on battery", isOn: $skipOnBattery)
                VStack(alignment: .leading) {
                    Text("Action Chain (JSON)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $actionsJSON)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        .onChange(of: actionsJSON) { _, v in validateActions(v) }
                    if let err = actionsError {
                        Text(err).font(.caption).foregroundStyle(BridgeTokens.bad)
                    }
                }
            }
            if let err = errorMsg {
                Text(err).font(.caption).foregroundStyle(BridgeTokens.bad)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Create Job") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(creating || name.isEmpty || scheduleError != nil || actionsError != nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .onAppear { validateSchedule(schedule); validateActions(actionsJSON) }
    }

    private func validateSchedule(_ s: String) {
        do { _ = try CronParser.parse(s); scheduleError = nil }
        catch { scheduleError = "\(error)" }
    }

    private func validateActions(_ s: String) {
        guard let data = s.data(using: .utf8) else { actionsError = "Invalid UTF-8"; return }
        do { _ = try JSONDecoder().decode([ActionStep].self, from: data); actionsError = nil }
        catch { actionsError = "Parse error: \(error.localizedDescription)" }
    }

    private func create() async {
        creating = true; defer { creating = false }
        guard let data = actionsJSON.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([ActionStep].self, from: data) else {
            await MainActor.run { errorMsg = "Invalid action JSON" }; return
        }
        var mcpActions: [MCP.Value] = []
        for step in parsed {
            var argsObj: [String: MCP.Value] = [:]
            for (k, v) in step.arguments { argsObj[k] = JSONValue.toMCP(v) }
            mcpActions.append(.object([
                "tool": .string(step.tool),
                "arguments": .object(argsObj),
                "onFail": .string(step.onFail.rawValue)
            ]))
        }
        let payload: MCP.Value = .object([
            "name": .string(name),
            "schedule": .string(schedule),
            "actions": .array(mcpActions),
            "skipOnBattery": .bool(skipOnBattery)
        ])
        do {
            _ = try await JobsManager.shared.createJob(args: payload)
            await onCreate()
        } catch {
            await MainActor.run { errorMsg = "Create failed: \(error)" }
        }
    }
}

// MARK: - JobDetailView (inline-expand editor)

struct JobDetailView: View {
    let job: JobRecord
    let onChanged: () -> Void

    @State private var editedName: String
    @State private var editedSchedule: String
    @State private var editedSkipBattery: Bool
    @State private var editedActionsJSON: String
    @State private var scheduleError: String?
    @State private var actionsError: String?
    @State private var saveMessage: String?
    @State private var running = false

    init(job: JobRecord, onChanged: @escaping () -> Void) {
        self.job = job
        self.onChanged = onChanged
        _editedName = State(initialValue: job.name)
        _editedSchedule = State(initialValue: job.schedule)
        _editedSkipBattery = State(initialValue: job.skipOnBattery)
        _editedActionsJSON = State(initialValue: JobDetailView.prettyPrint(job.actionChain))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBlock
            scheduleBlock
            actionsBlock
            optionsBlock
            footerActions
            if let msg = saveMessage {
                Text(msg).font(.caption).foregroundStyle(BridgeTokens.fg3)
            }
        }
        .padding(.horizontal, 2)
    }

    private func blockLabel(_ text: String) -> some View { BridgeCardLabel(text) }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Job name", text: $editedName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Label(job.id, systemImage: "number")
                    .font(.caption.monospaced())
                    .foregroundStyle(BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.id, forType: .string)
                    saveMessage = "Copied job id."
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy job id")

                Button { revealLog() } label: { Label("Reveal Log", systemImage: "doc.text.magnifyingglass") }
                .buttonStyle(.borderless)
            }
        }
    }

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockLabel("Schedule")
            TextField("* * * * *", text: $editedSchedule)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onChange(of: editedSchedule) { _, newValue in validateSchedule(newValue) }
            if let err = scheduleError {
                Text(err).font(.caption).foregroundStyle(BridgeTokens.bad)
            } else {
                Text((CronHumanizer.describe(editedSchedule) ?? editedSchedule))
                    .font(.caption).foregroundStyle(BridgeTokens.fg3)
            }
        }
    }

    private var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                blockLabel("Action Chain")
                Spacer()
                Text("JSON").font(.caption).foregroundStyle(BridgeTokens.fg5)
            }
            TextEditor(text: $editedActionsJSON)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(8)
                .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .onChange(of: editedActionsJSON) { _, newValue in validateActions(newValue) }
            if let err = actionsError {
                Text(err).font(.caption).foregroundStyle(BridgeTokens.bad)
            }
        }
    }

    private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Skip when on battery", isOn: $editedSkipBattery)
            Text("launchd will defer the job if the Mac is running on battery power.")
                .font(.caption).foregroundStyle(BridgeTokens.fg4)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button { Task { await runNow() } } label: { Label("Run Now", systemImage: "play.fill") }
                .disabled(running)
            Button { Task { await duplicate() } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if job.status == .active {
                Button { Task { await pause() } } label: { Label("Pause", systemImage: "pause.fill") }
            } else {
                Button { Task { await resume() } } label: { Label("Resume", systemImage: "play.fill") }
            }
            Spacer()
            Button(role: .destructive) { Task { await delete() } } label: { Label("Delete", systemImage: "trash") }
            Button { Task { await saveChanges() } } label: { Label("Save Changes", systemImage: "checkmark.circle.fill") }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(BridgeTokens.accent)
                .disabled(scheduleError != nil || actionsError != nil || !hasChanges)
        }
    }

    private var hasChanges: Bool {
        editedName != job.name ||
        editedSchedule != job.schedule ||
        editedSkipBattery != job.skipOnBattery ||
        editedActionsJSON != JobDetailView.prettyPrint(job.actionChain)
    }

    // MARK: Validation

    private func validateSchedule(_ s: String) {
        do { _ = try CronParser.parse(s); scheduleError = nil }
        catch { scheduleError = "\(error)" }
    }

    private func validateActions(_ s: String) {
        guard let data = s.data(using: .utf8) else { actionsError = "Invalid UTF-8"; return }
        do { _ = try JSONDecoder().decode([ActionStep].self, from: data); actionsError = nil }
        catch { actionsError = "Parse error: \(error.localizedDescription)" }
    }

    // MARK: Mutations (bindings preserved)

    private func saveChanges() async {
        guard let actionsData = editedActionsJSON.data(using: .utf8) else { return }
        let parsed: [ActionStep]
        do {
            parsed = try JSONDecoder().decode([ActionStep].self, from: actionsData)
        } catch {
            await MainActor.run { actionsError = "\(error)" }
            return
        }
        var mcpActions: [MCP.Value] = []
        for step in parsed {
            var argsObj: [String: MCP.Value] = [:]
            for (k, v) in step.arguments { argsObj[k] = JSONValue.toMCP(v) }
            mcpActions.append(.object([
                "tool": .string(step.tool),
                "arguments": .object(argsObj),
                "onFail": .string(step.onFail.rawValue)
            ]))
        }
        let payload: MCP.Value = .object([
            "id": .string(job.id),
            "name": .string(editedName),
            "schedule": .string(editedSchedule),
            "actions": .array(mcpActions),
            "skipOnBattery": .bool(editedSkipBattery)
        ])
        do {
            _ = try await JobsManager.shared.updateJobTool(args: payload)
            await MainActor.run { saveMessage = "Saved." }
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Save failed: \(error)" }
        }
    }

    private func runNow() async {
        running = true; defer { running = false }
        do {
            _ = try await JobsManager.shared.runNowTool(args: .object(["id": .string(job.id)]))
            await MainActor.run { saveMessage = "Run triggered." }
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Run failed: \(error)" }
        }
    }

    private func duplicate() async {
        do {
            _ = try await JobsManager.shared.duplicateJobTool(args: .object(["id": .string(job.id)]))
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Duplicate failed: \(error)" }
        }
    }

    private func pause() async {
        do {
            _ = try await JobsManager.shared.pauseJob(args: .object(["id": .string(job.id)]))
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Pause failed: \(error)" }
        }
    }

    private func resume() async {
        do {
            _ = try await JobsManager.shared.resumeJob(args: .object(["id": .string(job.id)]))
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Resume failed: \(error)" }
        }
    }

    private func delete() async {
        do {
            _ = try await JobsManager.shared.deleteJob(args: .object(["id": .string(job.id)]))
            onChanged()
        } catch {
            await MainActor.run { saveMessage = "Delete failed: \(error)" }
        }
    }

    private func revealLog() {
        // PKT-1 v3.5: BridgePaths.logs(.jobs) is the canonical home.
        let outLog = BridgePaths.logs(.jobs).appendingPathComponent("\(job.id).out.log")
        NSWorkspace.shared.activateFileViewerSelecting([outLog])
    }

    // MARK: JSON helpers

    static func prettyPrint(_ chain: [ActionStep]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(chain), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[]"
    }
}

// MARK: - Import sheet

struct ImportSheet: View {
    @Binding var jsonText: String
    var onCancel: () -> Void
    var onImport: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Jobs").font(.title2.bold())
            Text("Paste a jobs export JSON envelope. IDs will be regenerated to avoid collisions.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $jsonText)
                .font(.body.monospaced())
                .frame(minWidth: 500, minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Load from File…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) {
                        jsonText = s
                    }
                }
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Import") { onImport(jsonText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(jsonText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - JSONValue ↔ MCP.Value bridge (read-only helpers for UI)

import MCP

extension JSONValue {
    static func toMCP(_ v: JSONValue) -> MCP.Value {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(Int(i))
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let arr): return .array(arr.map { toMCP($0) })
        case .object(let o):
            var out: [String: MCP.Value] = [:]
            for (k, vv) in o { out[k] = toMCP(vv) }
            return .object(out)
        }
    }
}
