// JobsSection.swift — Settings → Jobs pane.
// v3.7.8 Settings-redesign (PKT-jobs) · density + consistency pass over the
// v3.7.3 locked mockup (design/ui_kits/the-bridge/Jobs.jsx):
//   - Shared `BridgeSettingsSectionHeader` (purple, clock.badge.checkmark) —
//     no more bespoke emerald orb / duplicated 22pt title. The 4-stat strip
//     (done·24h / running / paused / failing) rides in the header accessory
//     and dims during a load error so it never asserts false health.
//   - Page-level failing banner (shared `JobsFailingBanner`, also used by the
//     row) shown when an active job's most recent execution failed.
//   - "Scheduled jobs" card: filter + inline search (Sort folded into the
//     overflow), glass rows (3-slot trailing grid: next-run · status · actions).
//   - "Recent runs" card: an expandable run-log derived from job_executions
//     (✓/✗ mark · time · job · duration / error) with per-line .help reveal.
//
// Every store binding and action is preserved: JobStore.listAll +
// executions drive the data; JobsManager handles pause/resume/run/duplicate/
// delete/create/import/export/pause-all/resume-all verbatim. JobsSection() is
// still instantiated directly with a no-arg init.

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

    // Jobs density targets (spec: pad 18→14, inter-card gap →10). Kept local so
    // they don't perturb the shared BridgeTokens.Space scale other pages share.
    private let paneInset: CGFloat = 14
    private let cardGap: CGFloat = 10

    public var body: some View {
        ScrollView {
            VStack(spacing: cardGap) {
                header
                if failingCount > 0 {
                    JobsFailingBanner(
                        scale: .page,
                        summary: pageFailureSummary,
                        onRetry: firstFailingJob.map { job in { await retry(job) } }
                    )
                }
                scheduledCard
                recentRunsCard
            }
            .padding(paneInset)
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
    /// "Running" in the stat strip = active (scheduled) jobs that aren't failing.
    private var runningCount: Int {
        jobs.filter { $0.status == .active && lastExecByJob[$0.id]?.status != .failure }.count
    }
    private var failingCount: Int {
        jobs.filter { $0.status == .active && lastExecByJob[$0.id]?.status == .failure }.count
    }
    private var firstFailingJob: JobRecord? {
        jobs.first { $0.status == .active && lastExecByJob[$0.id]?.status == .failure }
    }

    // MARK: - Header (shared section header + stat strip accessory)

    private var header: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .jobs)
        return BridgeSettingsSectionHeader(
            title: spec.title,
            subtitle: "Scheduled tool calls Bridge runs on cron — even when no client is connected.",
            systemImage: spec.systemImage,
            tint: spec.tint
        ) {
            statStrip
        }
    }

    /// Four at-a-glance numbers: throughput leads (done · 24h), then the live
    /// fleet state. Dimmed during a load error so it never asserts "all healthy"
    /// (0/0/0) during an outage.
    private var statStrip: some View {
        HStack(spacing: 8) {
            statTile(value: "\(done24hCount)", label: "done · 24h", color: BridgeTokens.okText)
            statTile(value: "\(runningCount)", label: "running", color: BridgeTokens.fg2)
            statTile(value: "\(pausedCount)", label: "paused", color: BridgeTokens.warnText)
            statTile(value: "\(failingCount)", label: "failing",
                     color: failingCount > 0 ? BridgeTokens.badText : BridgeTokens.fg2)
        }
        .opacity(loadError == nil ? 1 : 0.35)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Job stats: \(done24hCount) done in 24 hours, \(runningCount) running, \(pausedCount) paused, \(failingCount) failing")
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
            // 11pt sentence-case label (holds the legibility floor; the audit
            // flagged the old 10pt all-caps label as sub-floor). No tracking /
            // uppercasing so four tiles still fit the header accessory.
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BridgeTokens.fg4)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 54)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
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

    // MARK: - Scheduled jobs card

    private var scheduledCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    BridgeCardLabel("Scheduled jobs")
                    Spacer()
                    Button { Task { await pauseAll() } } label: { Text("Pause all") }
                        .controlSize(.small)
                        .disabled(bulkInProgress || activeCount == 0)
                        .help("Pause every active job")
                    Button { showNewJobSheet = true } label: { Label("New job", systemImage: "plus") }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(BridgeTokens.accent)
                    overflowMenu
                }
                controlsRow
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

    private var controlsRow: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $statusFilter) {
                ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            searchField
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(BridgeTokens.fg4)
            TextField("Search jobs", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .accessibilityLabel("Search jobs")
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.vertical, 22)
        } else if let err = loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26)).foregroundStyle(BridgeTokens.warnText)
                Text("Couldn’t load scheduled jobs.")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(BridgeTokens.fg2)
                Text(err)
                    .font(.system(size: 11.5)).foregroundStyle(BridgeTokens.fg4)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .help(err)
                Button("Retry") { Task { await reload() } }.controlSize(.small)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
        } else if filteredJobs.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ForEach(Array(filteredJobs.enumerated()), id: \.element.id) { idx, job in
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
                    if idx < filteredJobs.count - 1 {
                        Rectangle().fill(BridgeTokens.hairlineFaint)
                            .frame(height: 0.5)
                            .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 34))
                .foregroundStyle(BridgeTokens.fg5)
            Text(jobs.isEmpty ? "No scheduled jobs yet" : "No jobs match this filter")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BridgeTokens.fg2)
            if jobs.isEmpty {
                Text("Create a job or import an export file to schedule background tool calls.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button("New Job") { showNewJobSheet = true }
                        .buttonStyle(.borderedProminent).tint(BridgeTokens.accent)
                    Button("Import…") { showImportSheet = true }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
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
