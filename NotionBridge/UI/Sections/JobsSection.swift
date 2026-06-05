// JobsSection.swift — Settings → Jobs pane.
// v3.7.3 redesign · matches design/ui_kits/the-bridge/Jobs.jsx (locked mockup):
//   - Glass hero: accent orb + active/paused/failing stat tiles (emerald /
//     amber / red), plus quick "Pause all" / "+ New job" actions.
//   - Failing-job alert banner (red) shown when an active job's most recent
//     execution failed.
//   - "Scheduled jobs" card: filter / search / sort controls + glass rows
//     (icon tile, name, mono cron + tool detail, next-run, status badge,
//     pause/resume + run-now icon-buttons, expandable inline editor).
//   - "Recent runs" card: an expandable run-log derived from job_executions
//     (✓/✗ mark · time · job · duration / error).
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

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                if failingCount > 0 { failingAlert }
                scheduledCard
                recentRunsCard
            }
            .padding(18)
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
    private var failingCount: Int {
        jobs.filter { $0.status == .active && lastExecByJob[$0.id]?.status == .failure }.count
    }
    private var firstFailingJob: JobRecord? {
        jobs.first { $0.status == .active && lastExecByJob[$0.id]?.status == .failure }
    }

    // MARK: - Hero

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BridgeTokens.ok.opacity(0.20))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(BridgeTokens.ok.opacity(0.45), lineWidth: 1))
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(BridgeTokens.okText)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Jobs")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text("Scheduled tool calls Bridge runs on cron — even when no client is connected.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    statTile(value: "\(activeCount)", label: "active", color: BridgeTokens.okText)
                    statTile(value: "\(pausedCount)", label: "paused", color: BridgeTokens.warnText)
                    statTile(value: "\(failingCount)", label: "failing", color: BridgeTokens.badText)
                }
            }
        }
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    // MARK: - Failing alert banner

    private var failingAlert: some View {
        let job = firstFailingJob
        let detail = job.flatMap { lastExecByJob[$0.id]?.errorMessage }
        let plural = failingCount == 1 ? "job is" : "jobs are"
        return BridgeGlassCard(padding: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(BridgeTokens.badText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failingCount) \(plural) failing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BridgeTokens.badText)
                    Text(failureSummary(job: job, detail: detail))
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.badText.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let job {
                    Button {
                        Task {
                            _ = try? await JobsManager.shared.runNowTool(args: .object(["id": .string(job.id)]))
                            await reload()
                        }
                    } label: {
                        Text("Retry now")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BridgeTokens.badText)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(BridgeTokens.bad.opacity(0.14), in: Capsule())
                            .overlay(Capsule().strokeBorder(BridgeTokens.bad.opacity(0.30), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BridgeTokens.bad.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(BridgeTokens.bad.opacity(0.26), lineWidth: 0.5)
        )
    }

    private func failureSummary(job: JobRecord?, detail: String?) -> String {
        if let job, let detail, !detail.isEmpty {
            return "\(job.name): \(detail)"
        }
        if let job { return "\(job.name) — last run failed. Open the row to inspect the log." }
        return "Open the failing row to inspect the log."
    }

    // MARK: - Scheduled jobs card

    private var scheduledCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    BridgeCardLabel("Scheduled jobs")
                    Spacer()
                    Button { Task { await pauseAll() } } label: { Text("Pause all") }
                        .controlSize(.small)
                        .disabled(bulkInProgress || activeCount == 0)
                    Button { showNewJobSheet = true } label: { Label("New job", systemImage: "plus") }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(BridgeTokens.accent)
                    Menu {
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
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                controlsRow
                Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5)
                content
                if let msg = bulkMessage {
                    Text(msg)
                        .font(.system(size: 11.5))
                        .foregroundStyle(msg.localizedCaseInsensitiveContains("failed")
                                         ? BridgeTokens.badText : BridgeTokens.fg4)
                        .lineLimit(1)
                }
            }
        }
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

            Picker("Sort", selection: $sortOption) {
                ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 170)
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
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
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
                Text(err).font(.system(size: 12)).foregroundStyle(BridgeTokens.fg3)
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
                            .padding(.vertical, 4)
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
            VStack(alignment: .leading, spacing: 10) {
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
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BridgeTokens.fg5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
                                    .foregroundStyle(BridgeTokens.fg2)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    if !runLogExpanded && recentRuns.count > 5 {
                        Text("+\(recentRuns.count - 5) more")
                            .font(.system(size: 11))
                            .foregroundStyle(BridgeTokens.fg5)
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
            await MainActor.run {
                self.jobs = all
                self.lastExecByJob = lastByJob
                self.recentRuns = runs
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
