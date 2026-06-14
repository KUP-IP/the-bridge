// JobsSection.swift — Settings → Jobs pane.
// v4 "Liquid Glass, evolved" redesign (PKT-jobs) · recreated from
// design/the-bridge-design-system/project/pages/page-jobs.jsx:
//   - Slim meta row (`.jbp-meta`) replaces the tall hero header: a "Scheduler"
//     label with a health BridgeBadge (Healthy / N failing), a mono counts
//     strip (done·24h · active · paused · failing — throughput leads), then the
//     primary actions (Pause all · New job). The strip dims during a load error
//     so it never asserts false health.
//   - Page-level failing banner — the shared `.bad` vocabulary at page scale via
//     the W2 `BridgeBanner(.bad)` with a live "Retry now" action (the in-row
//     banner is the same vocabulary at row scale, in JobGlassRow).
//   - "Scheduled jobs" card: glass card label + inline search (BridgeInput) +
//     segmented filter (BridgeSegmented All/Active/Paused) + overflow menu (Sort
//     folded in, plus resume-all / import / export). Glass rows (JobGlassRow)
//     carry the 3-slot trailing grid: next-run · status badge · actions.
//   - "Recent runs" card: an expandable run-log derived from job_executions
//     (✓/✗ mark · time · job · duration / error) with per-line .help reveal.
//
// Every store binding and action is preserved: JobStore.listAll + executions
// drive the data; JobsManager handles pause/resume/run/duplicate/delete/create/
// import/export/pause-all/resume-all verbatim. JobsSection() is still
// instantiated directly with a no-arg init. Both carbon + titanium resolve for
// free off the adaptive W1 tokens.

import SwiftUI
import AppKit
import MCP

public struct JobsSection: View {
    @State private var jobs: [JobRecord] = []
    @State private var lastExecByJob: [String: ExecutionRecord] = [:]
    @State private var recentRuns: [RunLine] = []
    @State private var done24hCount: Int = 0
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var expandedJobId: String?
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .nameAsc
    @State private var statusFilter: StatusFilter = .all
    @State private var runLogExpanded = false

    @State private var showNewJobSheet = false
    @State private var showImportSheet = false
    @State private var importJSONText = ""
    @State private var bulkInProgress = false
    @State private var bulkMessage: String?

    enum SortOption: String, CaseIterable, Identifiable {
        case nameAsc = "Name (A–Z)"
        case nameDesc = "Name (Z–A)"
        case updatedDesc = "Recently updated"
        case statusActive = "Active first"
        var id: String { rawValue }
    }

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case paused = "Paused"
        var id: String { rawValue }
    }

    /// A single rendered line in the "Recent runs" log.
    struct RunLine: Identifiable {
        let id: Int64
        let ok: Bool
        let time: String
        let text: String
    }

    public init() {}

    // Jobs density targets (spec: pane pad 18→14, inter-card gap →12). Kept
    // local so they don't perturb the shared BridgeTokens.Space scale.
    private let paneInset: CGFloat = 14
    private let cardGap: CGFloat = 12

    public var body: some View {
        VStack(spacing: 0) {
            // Slim meta row (`.jbp-meta`) — flush, with its own bottom hairline.
            metaRow
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)

            // Body (`.jbp-body`) — scrolls; page banner + cards.
            ScrollView {
                VStack(spacing: cardGap) {
                    if let job = firstFailingJob {
                        pageFailingBanner(for: job)
                    }
                    scheduledCard
                    recentRunsCard
                }
                .padding(paneInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .jobsDidChange)) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showNewJobSheet) {
            NewJobSheet(onCancel: { showNewJobSheet = false },
                        onCreate: { await reload(); showNewJobSheet = false })
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(jsonText: $importJSONText,
                        onCancel: { showImportSheet = false; importJSONText = "" },
                        onImport: { text in
                            Task {
                                await doImport(json: text)
                                showImportSheet = false
                                importJSONText = ""
                            }
                        })
        }
    }

    // MARK: - Derived counts

    private var activeCount: Int { jobs.filter { $0.status == .active }.count }
    private var pausedCount: Int { jobs.filter { $0.status == .paused }.count }
    /// "Running" in the strip = active (scheduled) jobs that aren't failing.
    private var runningCount: Int {
        jobs.filter { $0.status == .active && lastExecByJob[$0.id]?.status != .failure }.count
    }
    private var failingCount: Int {
        jobs.filter { $0.status == .active && lastExecByJob[$0.id]?.status == .failure }.count
    }
    private var firstFailingJob: JobRecord? {
        jobs.first { $0.status == .active && lastExecByJob[$0.id]?.status == .failure }
    }

    // MARK: - Slim meta row (`.jbp-meta`)

    /// Scheduler label + health badge · mono counts · spacer · Pause all · New job.
    private var metaRow: some View {
        HStack(spacing: 14) {
            // `.m-label`: glyph + "Scheduler" + the health badge.
            HStack(spacing: 9) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 14))
                    .foregroundStyle(BridgeTokens.fg2)
                Text("Scheduler")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg1)
                    .fixedSize()
                if failingCount > 0 {
                    BridgeBadge("\(failingCount) failing", tone: .bad, showsDot: true)
                } else {
                    BridgeBadge("Healthy", tone: .ok, showsDot: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(failingCount > 0
                                ? "Scheduler — \(failingCount) failing"
                                : "Scheduler — healthy")

            // `.m-counts`: mono throughput + fleet state (throughput leads).
            countsStrip
                .opacity(loadError == nil ? 1 : 0.35)

            Spacer(minLength: 8)

            BridgeButton("Pause all", systemImage: "pause",
                         isEnabled: !bulkInProgress && activeCount > 0) {
                Task { await pauseAll() }
            }
            .help("Pause every active job")
            BridgeButton("New job", systemImage: "plus", variant: .primary) {
                showNewJobSheet = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// `.m-counts` — mono `N done · 24h · N active · N paused · N failing`, the
    /// active/failing weights tinted by signal so the eye lands on trouble.
    private var countsStrip: some View {
        HStack(spacing: 0) {
            countNum("\(done24hCount)", color: BridgeTokens.fg2)
            countSep(" done · 24h")
            countDot()
            countNum("\(runningCount)", color: BridgeTokens.fg2)
            countSep(" active")
            countDot()
            countNum("\(pausedCount)", color: pausedCount > 0 ? BridgeTokens.warnText : BridgeTokens.fg2)
            countSep(" paused")
            countDot()
            countNum("\(failingCount)", color: failingCount > 0 ? BridgeTokens.badText : BridgeTokens.fg2)
            countSep(" failing")
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(done24hCount) done in 24 hours, \(runningCount) active, \(pausedCount) paused, \(failingCount) failing")
    }

    private func countNum(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color)
    }
    private func countSep(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(BridgeTokens.fg4)
    }
    private func countDot() -> some View {
        Text("  ·  ")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(BridgeTokens.fg5)
    }

    // MARK: - Failing summary copy (for the shared page banner)

    private var pageFailureSummary: String {
        let job = firstFailingJob
        let detail = job.flatMap { lastExecByJob[$0.id]?.errorMessage }
        let plural = failingCount == 1 ? "job is" : "jobs are"
        let head = "\(failingCount) \(plural) failing"
        if let job, let detail, !detail.isEmpty {
            return "\(head). \(job.name): \(detail)"
        }
        if let job {
            return "\(head). \(job.name) — last run failed. Open the row to inspect the log."
        }
        return "\(head). Open the failing row to inspect the log."
    }

    private func retry(_ job: JobRecord) async {
        _ = try? await JobsManager.shared.runNowTool(args: .object(["id": .string(job.id)]))
        await reload()
    }

    /// Page-scale failing banner — the shared `.bad` `BridgeBanner` with a live
    /// "Retry now" action that re-runs the (concrete) failing job.
    private func pageFailingBanner(for job: JobRecord) -> some View {
        BridgeBanner(
            signal: .bad,
            message: pageFailureSummary,
            systemImage: "exclamationmark.triangle"
        ) {
            RetryNowButton { await retry(job) }
        }
    }

    // MARK: - Scheduled jobs card

    private var scheduledCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    BridgeCardLabel("Scheduled jobs")
                    Spacer()
                    searchField
                    BridgeSegmented(selection: $statusFilter,
                                    options: StatusFilter.allCases.map { ($0, $0.rawValue) })
                        .fixedSize()
                    overflowMenu
                }
                Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5)
                content
                if let msg = bulkMessage {
                    Text(msg)
                        .font(.system(size: 11.5))
                        .foregroundStyle(msg.localizedCaseInsensitiveContains("failed")
                                         ? BridgeTokens.badText : BridgeTokens.fg4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Overflow: Sort (folded out of the always-visible control row to reclaim
    /// width), plus the bulk verbs / import-export.
    private var overflowMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button { Task { await resumeAll() } } label: { Label("Resume All", systemImage: "play.circle") }
                .disabled(bulkInProgress || pausedCount == 0)
            Divider()
            Button { Task { await exportAll() } } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .disabled(jobs.isEmpty)
            Button { showImportSheet = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
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
        .help("More actions — sort, resume all, import / export")
    }

    /// `.input` with a leading search glyph (`.jbp` filter field).
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(BridgeTokens.fg5)
            TextField("Filter jobs", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg1)
                .tint(BridgeTokens.accentStrong)
                .accessibilityLabel("Filter jobs")
        }
        .frame(width: 160, height: 30)
        .padding(.horizontal, 10)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous))
        .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.input)
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous)
            .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            BridgeLoadingView(rows: 4)
                .padding(.vertical, 6)
        } else if let err = loadError {
            BridgeErrorView(message: "Couldn’t load scheduled jobs. \(err)") {
                Task { await reload() }
            }
        } else if filteredJobs.isEmpty {
            emptyState
        } else {
            VStack(spacing: 3) {
                ForEach(Array(filteredJobs.enumerated()), id: \.element.id) { _, job in
                    JobGlassRow(
                        job: job,
                        lastExecution: lastExecByJob[job.id],
                        isExpanded: expandedJobId == job.id,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                expandedJobId = (expandedJobId == job.id ? nil : job.id)
                            }
                        },
                        onChanged: { Task { await reload() } }
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        Group {
            if jobs.isEmpty {
                BridgeEmptyStateView(
                    systemImage: "clock.badge.checkmark",
                    title: "No scheduled jobs yet",
                    message: "Create a job or import an export file to schedule background tool calls."
                ) {
                    HStack(spacing: 8) {
                        BridgeButton("New job", systemImage: "plus", variant: .primary) {
                            showNewJobSheet = true
                        }
                        BridgeButton("Import…") { showImportSheet = true }
                    }
                }
            } else {
                BridgeEmptyStateView(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: "No jobs match this filter",
                    message: "Try a different filter — or create one with New job."
                )
            }
        }
    }

    // MARK: - Recent runs card

    private var recentRunsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { runLogExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        BridgeCardLabel("Recent runs")
                        Spacer()
                        Text("Last 24 hours")
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.fg4)
                        Image(systemName: runLogExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(runLogExpanded ? "Collapse recent runs" : "Expand recent runs")

                if recentRuns.isEmpty {
                    Text("No runs recorded yet.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg4)
                } else {
                    let shown = runLogExpanded ? recentRuns : Array(recentRuns.prefix(5))
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(shown) { line in
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
                    if !runLogExpanded && recentRuns.count > 5 {
                        Text("+\(recentRuns.count - 5) more")
                            .font(.system(size: 11))
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                }
            }
        }
    }

    // MARK: - Derived list

    private var filteredJobs: [JobRecord] {
        var base = jobs
        switch statusFilter {
        case .all: break
        case .active: base = base.filter { $0.status == .active }
        case .paused: base = base.filter { $0.status == .paused }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            base = base.filter {
                $0.name.lowercased().contains(q) ||
                $0.schedule.lowercased().contains(q) ||
                $0.id.lowercased().contains(q)
            }
        }
        switch sortOption {
        case .nameAsc: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .updatedDesc: return base.sorted { $0.updatedAt > $1.updatedAt }
        case .statusActive: return base.sorted {
            ($0.status == .active ? 0 : 1, $0.name) < ($1.status == .active ? 0 : 1, $1.name)
        }
        }
    }

    // MARK: - Data

    private func reload() async {
        await MainActor.run { isLoading = true }
        do {
            let all = try await JobStore.shared.listAll(statusFilter: nil)
            // Pull recent executions per job to derive failing state + run log.
            var lastByJob: [String: ExecutionRecord] = [:]
            var allRecent: [ExecutionRecord] = []
            let nameById = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
            for job in all {
                let execs = (try? await JobStore.shared.executions(jobId: job.id, limit: 10)) ?? []
                if let latest = execs.first { lastByJob[job.id] = latest }
                allRecent.append(contentsOf: execs)
            }
            let runs = Self.buildRunLines(from: allRecent, nameById: nameById)
            let done24h = Self.successfulRunsLast24h(from: allRecent)
            await MainActor.run {
                self.jobs = all
                self.lastExecByJob = lastByJob
                self.recentRuns = runs
                self.done24hCount = done24h
                self.loadError = nil
                self.isLoading = false
                if let sel = self.expandedJobId, !all.contains(where: { $0.id == sel }) {
                    self.expandedJobId = nil
                }
            }
        } catch {
            await MainActor.run {
                self.loadError = "\(error)"
                self.isLoading = false
            }
        }
    }

    /// Throughput stat: successful executions whose start is within the last 24h.
    private static func successfulRunsLast24h(from execs: [ExecutionRecord]) -> Int {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return execs.filter { $0.status == .success && $0.startedAt >= cutoff }.count
    }

    /// Flatten executions into the most-recent run lines (capped), newest first.
    private static func buildRunLines(from execs: [ExecutionRecord],
                                      nameById: [String: String]) -> [RunLine] {
        let sorted = execs.sorted { $0.startedAt > $1.startedAt }.prefix(40)
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        return sorted.compactMap { e in
            guard let id = e.id else { return nil }
            let name = nameById[e.jobId] ?? e.jobId
            let ok = (e.status == .success)
            var text = name
            if let err = e.errorMessage, !ok, !err.isEmpty {
                text += " · \(err)"
            } else if let completed = e.completedAt {
                let ms = Int(completed.timeIntervalSince(e.startedAt) * 1000)
                text += " · \(ms)ms"
                if e.status != .success { text += " · \(e.status.rawValue)" }
            } else {
                text += " · \(e.status.rawValue)"
            }
            return RunLine(id: id, ok: ok, time: timeFmt.string(from: e.startedAt), text: text)
        }
    }

    // MARK: - Bulk actions (bindings preserved)

    private func pauseAll() async {
        bulkInProgress = true; defer { bulkInProgress = false }
        do {
            _ = try await JobsManager.shared.pauseAllTool(args: .object([:]))
            await reload()
            await MainActor.run { bulkMessage = "Paused all active jobs." }
        } catch {
            await MainActor.run { bulkMessage = "Pause all failed: \(error)" }
        }
    }

    private func resumeAll() async {
        bulkInProgress = true; defer { bulkInProgress = false }
        do {
            _ = try await JobsManager.shared.resumeAllTool(args: .object([:]))
            await reload()
            await MainActor.run { bulkMessage = "Resumed all paused jobs." }
        } catch {
            await MainActor.run { bulkMessage = "Resume all failed: \(error)" }
        }
    }

    private func exportAll() async {
        do {
            let result = try await JobsManager.shared.exportJobsTool(args: .object([:]))
            guard case .object(let o) = result, case .string(let json)? = o["json"] else { return }
            let panel = NSSavePanel()
            panel.title = "Export Jobs"
            panel.nameFieldStringValue = "notion-bridge-jobs.json"
            panel.allowedContentTypes = [.json]
            if panel.runModal() == .OK, let url = panel.url {
                try json.data(using: .utf8)?.write(to: url)
                await MainActor.run { bulkMessage = "Exported \(self.jobs.count) jobs." }
            }
        } catch {
            await MainActor.run { bulkMessage = "Export failed: \(error)" }
        }
    }

    private func doImport(json: String) async {
        do {
            _ = try await JobsManager.shared.importJobsTool(args: .object(["json": .string(json)]))
            await reload()
            await MainActor.run { bulkMessage = "Import complete." }
        } catch {
            await MainActor.run { bulkMessage = "Import failed: \(error)" }
        }
    }
}

// MARK: - Page-banner Retry action

/// The live "Retry now" action button hosted inside the page-scale failing
/// `BridgeBanner` — runs the failing job again and reflects an in-flight spinner.
/// Pulled out so the banner's trailing `action` slot stays a small, stateful view.
private struct RetryNowButton: View {
    let onRetry: () async -> Void
    @State private var retrying = false

    var body: some View {
        Button {
            guard !retrying else { return }
            Task { retrying = true; await onRetry(); retrying = false }
        } label: {
            HStack(spacing: 5) {
                if retrying { ProgressView().controlSize(.mini) }
                Text(retrying ? "Retrying…" : "Retry now")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BridgeTokens.badText)
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(BridgeTokens.bad.opacity(0.16), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(BridgeTokens.bad.opacity(0.32), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(retrying)
        .help("Run the failing job again now")
        .accessibilityLabel(retrying ? "Retrying" : "Retry now")
    }
}
