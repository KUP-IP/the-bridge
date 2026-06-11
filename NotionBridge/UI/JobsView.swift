// JobsView.swift — Settings > Jobs · shared row / detail / sheet components.
// NotionBridge · UI · v3.7.8 Settings-redesign (PKT-jobs)
//
// The Jobs page is owned end-to-end by JobsSection (the locked Liquid-Glass
// mockup — shared section header + 4-stat strip, failing banner, glass
// scheduled-job rows, expandable run-log). This file hosts the reusable pieces
// JobsSection composes:
//   • JobsFailingBanner — one failing-state banner at two scales (page + row)
//   • JobGlassRow       — one scheduled-job row: icon tile, name + mono cron +
//                         tool detail, and a fixed 3-slot trailing grid
//                         {next-run · status badge · actions}. The body taps to
//                         expand (no standalone chevron — a hover background
//                         signals it); the editor + a per-row run history live
//                         inside the expansion.
//   • JobDetailView     — the inline-expand editor (name/schedule/actions/options
//                         + Run/Duplicate/Pause/Delete/Save), re-glassed; bindings
//                         verbatim, cron validation + Save gating preserved.
//   • NewJobSheet       — +New job sheet (create)
//   • ImportSheet       — paste/load a jobs export
//
// EVERY store binding and action (JobsManager.*) is preserved verbatim — only
// the presentation moved. The public `JobsView` shim renders JobsSection so any
// stray caller still resolves to the redesigned page.

import SwiftUI
import AppKit

// MARK: - Public shim

/// Back-compat entry point. The Jobs page is rendered by ``JobsSection``;
/// this thin wrapper keeps `JobsView()` resolving to the redesigned page.
public struct JobsView: View {
    public init() {}
    public var body: some View { JobsSection() }
}

// MARK: - Shared failing banner (page + row)

/// One failing-state banner rendered at two scales so the page-level alert and
/// the in-row banner share a single layout/token vocabulary (the audit flagged
/// two divergent banners). `.page` carries an optional "Retry now" action;
/// `.row` is a compact inline notice.
struct JobsFailingBanner: View {
    enum Scale { case page, row }

    let scale: Scale
    let summary: String
    /// Optional retry handler (page scale only).
    var onRetry: (() async -> Void)?

    @State private var retrying = false

    private var iconSize: CGFloat { scale == .page ? 15 : 11 }
    private var titleSize: CGFloat { scale == .page ? 13 : 11.5 }
    private var radius: CGFloat { BridgeTokens.Radius.control }
    private var pad: CGFloat { scale == .page ? 12 : 9 }

    var body: some View {
        HStack(alignment: scale == .page ? .top : .top, spacing: scale == .page ? 11 : 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(BridgeTokens.badText)
            Text(summary)
                .font(.system(size: titleSize, weight: scale == .page ? .medium : .regular))
                .foregroundStyle(BridgeTokens.badText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if scale == .page, let onRetry {
                Button {
                    guard !retrying else { return }
                    Task { retrying = true; await onRetry(); retrying = false }
                } label: {
                    HStack(spacing: 5) {
                        if retrying { ProgressView().controlSize(.mini) }
                        Text(retrying ? "Retrying…" : "Retry now")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BridgeTokens.badText)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(BridgeTokens.bad.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(BridgeTokens.bad.opacity(0.30), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(retrying)
                .help("Run the failing job again now")
            }
        }
        .padding(.horizontal, pad).padding(.vertical, scale == .page ? pad : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BridgeTokens.bad.opacity(scale == .page ? 0.07 : 0.10),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(BridgeTokens.bad.opacity(0.26), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }
}

// MARK: - Scheduled-job row (glass)

/// One scheduled-job row in the "Scheduled jobs" card — an accent icon tile,
/// name + mono cron + tool detail, and a fixed 3-slot trailing grid
/// {next-run · status badge · action cluster}. Tapping the body toggles the
/// inline editor (a hover background is the affordance — the standalone chevron
/// is gone). Run-now shows an in-row spinner + toast and, for action chains that
/// touch send/payment/delete tools, prompts to confirm first.
struct JobGlassRow: View {
    let job: JobRecord
    /// Most-recent execution for this job, if any — drives the failing banner
    /// + run-now ("retry") affordance. Derived by JobsSection from the store.
    let lastExecution: ExecutionRecord?
    let isExpanded: Bool
    let onToggle: () -> Void
    let onChanged: () -> Void

    @State private var busy = false
    @State private var running = false
    @State private var hovering = false
    @State private var toast: String?
    @State private var showRunConfirm = false

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
        .background(
            RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                .fill((hovering || isExpanded) ? BridgeTokens.hoverFill : Color.clear)
        )
        .confirmationDialog(
            "Run “\(job.name)” now?",
            isPresented: $showRunConfirm,
            titleVisibility: .visible
        ) {
            Button("Run now", role: .destructive) { Task { await runNow() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This job can send messages, move money, or delete data. Running it now executes those actions immediately.")
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
                    .help(job.name)
                subline
                if isFailing {
                    JobsFailingBanner(
                        scale: .row,
                        summary: lastExecution?.errorMessage ?? "Last run failed — check the job log.",
                        onRetry: nil
                    )
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 8)
            trailingGrid
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .onHover { hovering = $0 }
        // The whole row is a combined element: a VO user hears one summary, then
        // the action buttons (their own elements) follow.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.name), \(tone.badge), \(nextRunText)")
        .accessibilityHint(isExpanded ? "Collapse to hide the editor" : "Expand to edit and view history")
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
        .accessibilityHidden(true)
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
                .help(detailText)
        }
    }

    /// Fixed 3-slot trailing grid {next-run · status badge · action cluster} so
    /// the right edge stops being a traffic jam and columns line up across rows.
    private var trailingGrid: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(nextRunText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(nextRunHelp)
                statusBadge
            }
            actions
        }
    }

    private var statusBadge: some View {
        Text(tone.badge)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.badgeFG)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(tone.badgeBG, in: Capsule())
            .overlay(Capsule().strokeBorder(tone.dot.opacity(0.30), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: 3) {
            if job.status == .active {
                iconButton("pause.fill", help: "Pause", a11y: "Pause \(job.name)") { await pause() }
            } else {
                iconButton("play.fill", help: "Resume", a11y: "Resume \(job.name)") { await resume() }
            }
            runNowButton
            Menu {
                Button { requestRun() } label: { Label("Run Now", systemImage: "play.fill") }
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
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More — duplicate, copy id, delete")
            .accessibilityLabel("More actions for \(job.name)")
        }
        .padding(.top, 1)
    }

    /// Run-now is always visible; it shows an in-row spinner while running and a
    /// toast on completion. For side-effecting chains it routes through a confirm.
    private var runNowButton: some View {
        Button {
            requestRun()
        } label: {
            ZStack {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(BridgeTokens.fg3)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(needsRunConfirm ? "Run now (asks to confirm — has side effects)" : "Run now")
        .disabled(running || busy)
        .accessibilityLabel("Run \(job.name) now")
        .overlay(alignment: .topTrailing) { toastOverlay }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BridgeTokens.fg1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(BridgeTokens.chipFill, in: Capsule())
                .overlay(Capsule().strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .fixedSize()
                .offset(y: -22)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    private func iconButton(_ systemImage: String, help: String, a11y: String,
                            action: @escaping () async -> Void) -> some View {
        Button {
            guard !busy else { return }
            Task { busy = true; await action(); busy = false }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BridgeTokens.fg3)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(busy)
        .accessibilityLabel(a11y)
    }

    // MARK: row actions (bindings preserved)

    /// Whether this job's action chain touches a side-effecting tool family
    /// (send / payment / delete) — gate run-now behind a confirm if so.
    private var needsRunConfirm: Bool {
        job.actionChain.contains { step in
            let t = step.tool.lowercased()
            return t.contains("send") || t.contains("message")
                || t.contains("mail") || t.contains("payment") || t.contains("invoice")
                || t.contains("charge") || t.contains("refund") || t.contains("subscription")
                || t.contains("stripe") || t.contains("delete") || t.contains("remove")
                || t.contains("cancel")
        }
    }

    private func requestRun() {
        guard !running else { return }
        if needsRunConfirm {
            showRunConfirm = true
        } else {
            Task { await runNow() }
        }
    }

    private func pause() async {
        _ = try? await JobsManager.shared.pauseJob(args: .object(["id": .string(job.id)]))
        onChanged()
    }
    private func resume() async {
        _ = try? await JobsManager.shared.resumeJob(args: .object(["id": .string(job.id)]))
        onChanged()
    }
    private func runNow() async {
        running = true; defer { running = false }
        _ = try? await JobsManager.shared.runNowTool(args: .object(["id": .string(job.id)]))
        await MainActor.run { flashToast("Run triggered") }
        onChanged()
    }

    private func flashToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.15)) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run { withAnimation(.easeInOut(duration: 0.2)) { toast = nil } }
        }
    }

    // MARK: derived text

    private var detailText: String {
        if let primary = job.actionChain.first {
            let extra = job.actionChain.count > 1 ? " +\(job.actionChain.count - 1)" : ""
            return primary.tool + extra
        }
        return CronHumanizer.describe(job.schedule) ?? "no actions"
    }

    /// Compact next-run hint. Paused → "paused"; failing → "retrying…";
    /// active → the ACTUAL next fire time (relative for near, clock for far),
    /// falling back to the humanized cadence if the schedule can't be resolved.
    private var nextRunText: String {
        if job.status == .paused { return "paused" }
        if isFailing { return "retrying…" }
        if let next = JobScheduleClock.nextFireDate(for: job.schedule) {
            return JobScheduleClock.relativeNextRun(next)
        }
        return CronHumanizer.describe(job.schedule) ?? "scheduled"
    }

    /// Tooltip carries the absolute next fire time for active jobs.
    private var nextRunHelp: String {
        if job.status == .paused { return "Paused — won’t run until resumed." }
        if isFailing { return "Last run failed; will retry on the next scheduled tick." }
        if let next = JobScheduleClock.nextFireDate(for: job.schedule) {
            return "Next run: \(JobScheduleClock.absolute(next))"
        }
        return CronHumanizer.describe(job.schedule) ?? job.schedule
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

// MARK: - Schedule clock (actual next-fire-time)

/// Computes the next fire time from a 5-field cron schedule using the
/// authoritative `CronParser` expansion + `Calendar.nextDate`, and formats it
/// for the row's next-run slot. Read-only; no scheduling side effects.
enum JobScheduleClock {
    /// The soonest future fire date across all expanded intervals, or nil if the
    /// schedule can't be parsed / resolved.
    static func nextFireDate(for schedule: String, from now: Date = Date()) -> Date? {
        guard let intervals = try? CronParser.parse(schedule), !intervals.isEmpty else { return nil }
        let cal = Calendar.current
        var soonest: Date?
        for iv in intervals {
            var comps = DateComponents()
            comps.minute = iv.minute
            comps.hour = iv.hour
            comps.day = iv.day
            comps.month = iv.month
            if let wd = iv.weekday { comps.weekday = wd + 1 } // cron 0=Sun → Calendar 1=Sun
            if let next = cal.nextDate(after: now, matching: comps,
                                       matchingPolicy: .nextTime,
                                       repeatedTimePolicy: .first,
                                       direction: .forward) {
                if soonest == nil || next < soonest! { soonest = next }
            }
        }
        return soonest
    }

    /// "next in 12m" / "next in 3h" / "tomorrow 06:00" / "Mon 09:00".
    static func relativeNextRun(_ date: Date, from now: Date = Date()) -> String {
        let delta = date.timeIntervalSince(now)
        if delta < 0 { return "due now" }
        let mins = Int(delta / 60)
        if mins < 1 { return "next <1m" }
        if mins < 60 { return "next in \(mins)m" }
        let hours = mins / 60
        let cal = Calendar.current
        if cal.isDateInToday(date) && hours < 12 { return "next in \(hours)h" }
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        if cal.isDateInToday(date) { return "today \(tf.string(from: date))" }
        if cal.isDateInTomorrow(date) { return "tomorrow \(tf.string(from: date))" }
        let wf = DateFormatter(); wf.dateFormat = "EEE HH:mm"
        return wf.string(from: date)
    }

    /// Absolute medium date+time for tooltips.
    static func absolute(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
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
                    Text(err).font(.caption).foregroundStyle(BridgeTokens.badText)
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
                        Text(err).font(.caption).foregroundStyle(BridgeTokens.badText)
                    }
                }
            }
            if let err = errorMsg {
                Text(err).font(.caption).foregroundStyle(BridgeTokens.badText)
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

// MARK: - JobDetailView (inline-expand editor — re-glassed)

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

    // Per-row run history (loaded on expand) — so "this job's recent runs" has
    // an in-app path; Reveal Log is the fallback, not the only route.
    @State private var history: [HistoryLine] = []
    @State private var historyLoaded = false

    struct HistoryLine: Identifiable {
        let id: Int64
        let ok: Bool
        let time: String
        let text: String
    }

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
            historyBlock
            footerActions
            if let msg = saveMessage {
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundStyle(msg.localizedCaseInsensitiveContains("failed")
                                     ? BridgeTokens.badText : BridgeTokens.fg3)
            }
        }
        .padding(.horizontal, 2)
        .task { await loadHistory() }
    }

    private func blockLabel(_ text: String) -> some View { BridgeCardLabel(text) }

    /// A glass well wrapper for editor fields so the editor matches the row's
    /// material instead of dropping to native `.roundedBorder`.
    private func glassField<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input))
            .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input)
                .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            glassField {
                TextField("Job name", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .accessibilityLabel("Job name")
            }
            HStack(spacing: 8) {
                Label(job.id, systemImage: "number")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.id)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.id, forType: .string)
                    saveMessage = "Copied job id."
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                .buttonStyle(.borderless)
                .help("Copy job id")
                .accessibilityLabel("Copy job id")

                Button { revealLog() } label: {
                    Label("Reveal Log", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Open the raw .out.log in Finder")
            }
        }
    }

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockLabel("Schedule")
            glassField {
                TextField("* * * * *", text: $editedSchedule)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onChange(of: editedSchedule) { _, newValue in validateSchedule(newValue) }
                    .accessibilityLabel("Cron schedule")
            }
            if let err = scheduleError {
                Text(err).font(.system(size: 11.5)).foregroundStyle(BridgeTokens.badText)
            } else {
                Text((CronHumanizer.describe(editedSchedule) ?? editedSchedule))
                    .font(.system(size: 11.5)).foregroundStyle(BridgeTokens.fg3)
            }
        }
    }

    private var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                blockLabel("Action Chain")
                Spacer()
                Text("JSON").font(.system(size: 11)).foregroundStyle(BridgeTokens.fg5)
            }
            TextEditor(text: $editedActionsJSON)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(8)
                .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input))
                .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .onChange(of: editedActionsJSON) { _, newValue in validateActions(newValue) }
                .accessibilityLabel("Action chain JSON")
            if let err = actionsError {
                Text(err).font(.system(size: 11.5)).foregroundStyle(BridgeTokens.badText)
            }
        }
    }

    private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Skip when on battery", isOn: $editedSkipBattery)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Skip when on battery")
            Text("launchd will defer the job if the Mac is running on battery power.")
                .font(.system(size: 11.5)).foregroundStyle(BridgeTokens.fg4)
        }
    }

    @ViewBuilder
    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockLabel("Recent runs")
            if !historyLoaded {
                HStack { ProgressView().controlSize(.mini); Text("Loading…").font(.system(size: 11.5)).foregroundStyle(BridgeTokens.fg4) }
            } else if history.isEmpty {
                Text("No runs recorded for this job yet.")
                    .font(.system(size: 11.5)).foregroundStyle(BridgeTokens.fg4)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(history) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.ok ? "✓" : "✗")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(line.ok ? BridgeTokens.okText : BridgeTokens.badText)
                            Text(line.time)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(BridgeTokens.fg4)
                                .monospacedDigit()
                            Text(line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(line.ok ? BridgeTokens.fg2 : BridgeTokens.badText)
                                .lineLimit(line.ok ? 1 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .help(line.text)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            }
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
        .controlSize(.small)
    }

    private var hasChanges: Bool {
        editedName != job.name ||
        editedSchedule != job.schedule ||
        editedSkipBattery != job.skipOnBattery ||
        editedActionsJSON != JobDetailView.prettyPrint(job.actionChain)
    }

    // MARK: History

    private func loadHistory() async {
        let execs = (try? await JobStore.shared.executions(jobId: job.id, limit: 8)) ?? []
        let tf = DateFormatter(); tf.dateFormat = "MMM d HH:mm"
        let lines: [HistoryLine] = execs.compactMap { e in
            guard let id = e.id else { return nil }
            let ok = (e.status == .success)
            var text: String
            if let err = e.errorMessage, !ok, !err.isEmpty {
                text = err
            } else if let completed = e.completedAt {
                let ms = Int(completed.timeIntervalSince(e.startedAt) * 1000)
                text = "\(ms)ms"
                if e.status != .success { text += " · \(e.status.rawValue)" }
            } else {
                text = e.status.rawValue
            }
            return HistoryLine(id: id, ok: ok, time: tf.string(from: e.startedAt), text: text)
        }
        await MainActor.run {
            self.history = lines
            self.historyLoaded = true
        }
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
