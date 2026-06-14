// JobsView.swift — Settings > Jobs · shared row / detail / sheet components.
// NotionBridge · UI · v4 "Liquid Glass, evolved" redesign (PKT-jobs)
//
// The Jobs page is owned end-to-end by JobsSection (the v4 design — slim meta
// row, page failing banner, glass scheduled-job rows, expandable inline editor
// + per-row run history). This file hosts the reusable pieces JobsSection
// composes, recreated faithfully from
// design/the-bridge-design-system/project/pages/page-jobs.jsx:
//   • JobsFailingBanner — one failing-state notice at two scales. `.row` is the
//     compact in-row banner (`.jbp-rowbanner`); the `.page` scale defers to the
//     W2 `BridgeBanner(.bad)` JobsSection renders directly (with live Retry).
//   • JobGlassRow       — one scheduled-job row: tone-tinted icon tile, name +
//     mono cron + humanized cadence + tool detail, and a fixed trailing grid
//     {next-run · BridgeBadge status · pause/run actions}. The body taps to
//     expand (a hover/open fill is the affordance — no standalone chevron); the
//     re-glassed editor + a per-row run history live inside the expansion.
//   • JobDetailView     — the inline-expand editor (name/schedule/actions/options
//     + Run/Duplicate/Pause/Delete/Save), re-glassed onto W2 inputs + buttons;
//     bindings verbatim, cron validation + Save gating preserved.
//   • NewJobSheet       — +New job sheet (create)
//   • ImportSheet       — paste/load a jobs export
//
// EVERY store binding and action (JobsManager.* / JobStore.*) is preserved
// verbatim — only the presentation moved to the W1 tokens + W2 components.
// Both carbon + titanium themes resolve for free off the adaptive tokens.
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

// MARK: - Shared failing banner (row scale)

/// The compact in-row failing notice (`.jbp-rowbanner`): a `.bad`-tinted strip
/// with a triangle glyph + message, shown under a failing job's subline when the
/// row is collapsed. The page-scale banner is the W2 `BridgeBanner(.bad)` that
/// JobsSection renders directly (it carries the live "Retry now" action), so the
/// two share the design's single `.bad` banner vocabulary at two scales.
struct JobsFailingBanner: View {
    let summary: String

    private var radius: CGFloat { BridgeTokens.Radius.control }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(BridgeTokens.badText)
            Text(summary)
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.badText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `.jbp-rowbanner`: bad@10% fill, bad@26% border.
        .background(BridgeTokens.bad.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(BridgeTokens.bad.opacity(0.26), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }
}

// MARK: - Scheduled-job row (glass)

/// One scheduled-job row in the "Scheduled jobs" card — a tone-tinted icon tile,
/// name + mono cron + humanized cadence + tool detail, and a fixed trailing grid
/// {next-run · status badge · action cluster}. Tapping the body toggles the
/// inline editor (a hover/open background is the affordance — the standalone
/// chevron is gone). Run-now shows an in-row spinner + toast and, for action
/// chains that touch send/payment/delete tools, prompts to confirm first.
/// `.jbp-row` / `.jbp-rowhead` / `.jbp-tile` / `.jbp-trail`.
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

    private var tone: BridgeSignal {
        if isFailing { return .bad }
        return job.status == .active ? .ok : .warn
    }

    /// The status-badge label + BridgeBadge tone for this job's state.
    private var badgeLabel: String {
        switch tone { case .ok: return "Active"; case .warn: return "Paused"; default: return "Failing" }
    }
    private var badgeTone: BridgeBadge.Tone {
        switch tone { case .ok: return .ok; case .warn: return .warn; default: return .bad }
    }

    var body: some View {
        VStack(spacing: 0) {
            rowHeader
            if isExpanded {
                // `.jbp-ed` is indented under the icon tile; the hairline divides
                // the head from the editor (`.jbp-ed .hair`).
                Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5)
                    .padding(.top, 9)
                    .padding(.leading, 41)   // clears the 30pt tile + 11pt gap
                JobDetailView(job: job, onChanged: onChanged)
                    .padding(.top, 12)
                    .padding(.leading, 41)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
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

    /// `.jbp-row` background: open → `well-deep` + raise edge + inset bevel;
    /// hover → `hover` fill; else clear. Border is a transparent→edge swap.
    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isExpanded {
            shape.fill(BridgeTokens.wellFillDeep)
                .overlay(shape.strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
                .bridgeBevel(BridgeTokens.bevelInset, radius: 10)
        } else if hovering {
            shape.fill(BridgeTokens.hoverFill)
        } else {
            Color.clear
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
                if isFailing && !isExpanded {
                    JobsFailingBanner(
                        summary: lastExecution?.errorMessage ?? "Last run failed — check the job log."
                    )
                    .padding(.top, 7)
                }
            }
            Spacer(minLength: 8)
            trailingGrid
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        // The whole header is a combined element: a VO user hears one summary,
        // then the action buttons (their own elements) follow.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.name), \(badgeLabel), \(nextRunText)")
        .accessibilityHint(isExpanded ? "Collapse to hide the editor" : "Expand to edit and view history")
    }

    /// `.jbp-tile`: a 30pt chip-fill well with a tone-tinted family glyph.
    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BridgeTokens.chipFill)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            Image(systemName: jobGlyph)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tone.text)
        }
        .frame(width: 30, height: 30)
        .padding(.top, 1)
        .accessibilityHidden(true)
    }

    /// `.jbp-sub`: mono cron · faint dot · humanized cadence + primary tool (+N).
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

    /// Fixed trailing grid {next-run · status badge · action cluster} so the
    /// right edge stops being a traffic jam and columns line up across rows.
    /// `.jbp-trail` / `.jbp-nextcol`.
    private var trailingGrid: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(nextRunText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(job.status == .active && !isFailing
                                     ? BridgeTokens.fg3 : BridgeTokens.fg5)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(nextRunHelp)
                BridgeBadge(badgeLabel, tone: badgeTone, showsDot: true)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: 96, alignment: .trailing)
            actions
        }
    }

    /// `.jbp-acts`: pause/resume · run-now (spinner + toast). The overflow menu
    /// (duplicate / copy id / delete) rides here too — kept from the shipped row
    /// so those verbs stay reachable directly on the row.
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

    /// `.jbp-ibtn`: a 28pt borderless icon button (hover → hoverFill + fg1).
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

    /// `.jbp-toast`: a popover-elevation pill that flashes the run result.
    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BridgeTokens.fg1)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(BridgeTokens.glassPopover.paint(in: Capsule(style: .continuous)))
                .overlay(Capsule(style: .continuous).strokeBorder(BridgeTokens.edgeRaise, lineWidth: 0.5))
                .bridgeShadow(BridgeTokens.shadowE2)
                .fixedSize()
                .offset(y: -24)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
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
        let cadence = CronHumanizer.describe(job.schedule)
        if let primary = job.actionChain.first {
            let extra = job.actionChain.count > 1 ? " +\(job.actionChain.count - 1)" : ""
            if let cadence { return "\(cadence) · \(primary.tool)\(extra)" }
            return primary.tool + extra
        }
        return cadence ?? "no actions"
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
        if tool.contains("credential") || tool.contains("token") || tool.contains("vault") { return "key" }
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
        VStack(alignment: .leading, spacing: 14) {
            Text("New scheduled job").font(BridgeTokens.Typeface.hero)
                .foregroundStyle(BridgeTokens.fg1)

            VStack(alignment: .leading, spacing: 6) {
                BridgeCardLabel("Name")
                BridgeInput("Job name", text: $name)
            }

            VStack(alignment: .leading, spacing: 6) {
                BridgeCardLabel("Schedule")
                BridgeInput("* * * * *", text: $schedule, mono: true)
                    .onChange(of: schedule) { _, v in validateSchedule(v) }
                if let err = scheduleError {
                    Text(err).font(.system(size: 11.5)).foregroundStyle(BridgeTokens.badText)
                } else {
                    Text((CronHumanizer.describe(schedule) ?? schedule))
                        .font(.system(size: 11.5)).foregroundStyle(BridgeTokens.fg3)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    BridgeCardLabel("Action chain")
                    Spacer()
                    Text("JSON").font(.system(size: 11)).foregroundStyle(BridgeTokens.fg5)
                }
                jsonEditor(text: $actionsJSON)
                    .frame(minHeight: 140)
                    .onChange(of: actionsJSON) { _, v in validateActions(v) }
                if let err = actionsError {
                    Text(err).font(.system(size: 11.5)).foregroundStyle(BridgeTokens.badText)
                }
            }

            Toggle("Skip when on battery", isOn: $skipOnBattery)
                .toggleStyle(.switch).controlSize(.small)

            if let err = errorMsg {
                Text(err).font(.system(size: 11.5)).foregroundStyle(BridgeTokens.badText)
            }
            HStack(spacing: 8) {
                Spacer()
                BridgeButton("Cancel") { onCancel() }
                BridgeButton("Create job", systemImage: "plus", variant: .primary,
                             isEnabled: !creating && !name.isEmpty && scheduleError == nil && actionsError == nil) {
                    Task { await create() }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .background(BridgeTokens.bgRaised)
        .onAppear { validateSchedule(schedule); validateActions(actionsJSON) }
    }

    /// A glass-well TextEditor for the JSON chain (matches `.jbp-json`).
    private func jsonEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input))
            .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input)
                .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            .accessibilityLabel("Action chain JSON")
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
        // Stop body taps from bubbling to the row header (which would collapse).
        .contentShape(Rectangle())
        .onTapGesture {}
        .task { await loadHistory() }
    }

    /// `.jbp-idrow`: mono job id · copy · reveal-log link.
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            BridgeInput("Job name", text: $editedName)
                .accessibilityLabel("Job name")
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

                BridgeButton("Reveal log", systemImage: "doc.text.magnifyingglass", variant: .link) {
                    revealLog()
                }
                .help("Open the raw .out.log in Finder")
            }
        }
    }

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            BridgeCardLabel("Schedule")
            BridgeInput("* * * * *", text: $editedSchedule, mono: true)
                .onChange(of: editedSchedule) { _, newValue in validateSchedule(newValue) }
                .accessibilityLabel("Cron schedule")
            // `.jbp-echo`: humanized echo or the validation error.
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
                BridgeCardLabel("Action chain")
                Spacer()
                Text("JSON").font(.system(size: 11)).foregroundStyle(BridgeTokens.fg5)
            }
            // `.jbp-json`: deep-well mono editor with inset bevel.
            TextEditor(text: $editedActionsJSON)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(8)
                .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input))
                .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.input)
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

    /// `.jbp-runs`: per-job run history (✓/✗ mark · time · result), in a well.
    @ViewBuilder
    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            BridgeCardLabel("Recent runs")
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
                .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
                .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.control)
            }
        }
    }

    /// `.jbp-foot`: Run / Duplicate / Pause-Resume · spacer · Delete · Save.
    private var footerActions: some View {
        HStack(spacing: 8) {
            BridgeButton("Run now", systemImage: "play.fill", isEnabled: !running) {
                Task { await runNow() }
            }
            BridgeButton("Duplicate") { Task { await duplicate() } }
            if job.status == .active {
                BridgeButton("Pause") { Task { await pause() } }
            } else {
                BridgeButton("Resume") { Task { await resume() } }
            }
            Spacer()
            BridgeButton("Delete", variant: .danger) { Task { await delete() } }
            BridgeButton("Save changes", systemImage: "checkmark", variant: .primary,
                         isEnabled: scheduleError == nil && actionsError == nil && hasChanges) {
                Task { await saveChanges() }
            }
        }
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Import jobs").font(BridgeTokens.Typeface.hero)
                .foregroundStyle(BridgeTokens.fg1)
            Text("Paste a jobs export JSON envelope. IDs will be regenerated to avoid collisions.")
                .font(.system(size: 11.5)).foregroundStyle(BridgeTokens.fg3)
            TextEditor(text: $jsonText)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(minWidth: 500, minHeight: 280)
                .padding(8)
                .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input))
                .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input)
                    .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            HStack(spacing: 8) {
                BridgeButton("Load from file…", systemImage: "folder") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) {
                        jsonText = s
                    }
                }
                Spacer()
                BridgeButton("Cancel") { onCancel() }
                BridgeButton("Import", variant: .primary,
                             isEnabled: !jsonText.trimmingCharacters(in: .whitespaces).isEmpty) {
                    onImport(jsonText)
                }
            }
        }
        .padding(20)
        .background(BridgeTokens.bgRaised)
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
