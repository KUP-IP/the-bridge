// CursorAgentsWindow.swift — PKT-3.4.2 Wave 4 (Bridge v2.2)
// NotionBridge · UI
//
// Standalone NSWindow surface for the Cursor agent management UI. Per PM
// Decision #40 (Reflow #23, Option B) the agent surface is a dedicated
// window — like SettingsWindow / OnboardingWindow — rather than a tab inside
// the menu bar popover, because the 3-pane UX spec from chat thread
// 2026-05-10 07:50 CT can't fit the 320pt popover.
//
// Layout (NSWindow 1000×620pt):
//   ┌────────────┬───────────────────┬───────────────────────────────┐
//   │  Filters   │   Agent list      │   Detail                      │
//   │  (240pt)   │   (320pt)         │   (flexible)                  │
//   └────────────┴───────────────────┴───────────────────────────────┘
// Filters: status (all/running/ready/error/completed) · runtime (all/local/cloud) ·
//          repo dropdown · model dropdown.
// List: sortable rows (status, started_at, repo, model, runtime, elapsed, cost).
// Detail: cost banner (today total / soft / hard) + agent identity + timeline
//         placeholder (Wave 5 wires SSE event stream) + artifact chips +
//         Stop button when running.
//
// Data sources:
//   • CursorAgentRegistry.shared — @MainActor ObservableObject; @ObservedObject.
//   • CursorCostLedger.shared — actor; pulled via .task + Notification refresh.
//
// Wave 5 will extend this surface with the new-run modal, heartbeat watchdog
// visualization, and SSE event timeline. Wave 4 ships the structural shell
// against current registry data so the UI is exercisable end-to-end the
// moment PKT-3.4.1.W2 lands the real event stream.

import SwiftUI
import AppKit
import NotionBridgeLib

// MARK: - Controller

/// Manages the standalone Cursor Agents NSWindow. Mirrors the
/// `OnboardingWindowController` / `SettingsWindowController` pattern used
/// elsewhere in the app.
@MainActor
public final class CursorAgentsWindowController {
    private var window: NSWindow?

    public init() {}

    /// Show (or bring to front) the Cursor Agents window.
    public func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = CursorAgentsView(
            registry: CursorAgentRegistry.shared,
            ledger: CursorCostLedger.shared
        )
        let hostingController = NSHostingController(rootView: rootView)

        let win = NSWindow(contentViewController: hostingController)
        win.title = "Cursor Agents"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 1000, height: 620))
        win.contentMinSize = NSSize(width: 820, height: 480)
        win.center()
        win.isReleasedWhenClosed = false

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("[CursorAgentsWindow] Shown")
    }
}

// MARK: - Root View

@MainActor
struct CursorAgentsView: View {
    @ObservedObject var registry: CursorAgentRegistry
    let ledger: CursorCostLedger

    // Filter state
    @State private var statusFilter: StatusFilter = .all
    @State private var runtimeFilter: RuntimeFilter = .all
    @State private var repoFilter: String? = nil   // nil = all
    @State private var modelFilter: String? = nil  // nil = all
    @State private var selectedRunId: String? = nil

    // Cost ledger snapshot (refreshed via .task + NotificationCenter observer)
    @State private var costToday: CursorCostDay? = nil
    @State private var costTier: CursorCostCapTier = .under

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, running, ready, error, completed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .running: return "Running"
            case .ready: return "Ready"
            case .error: return "Error"
            case .completed: return "Completed"
            }
        }
    }

    enum RuntimeFilter: String, CaseIterable, Identifiable {
        case all, local, cloud
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .local: return "Local"
            case .cloud: return "Cloud"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            filtersPane
                .frame(width: 240)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            listPane
                .frame(width: 320)

            Divider()

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 480)
        .task {
            await refreshCost()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .cursorAgentCostCapTripped)
        ) { _ in
            Task { await refreshCost() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .cursorAgentStateDidChange)
        ) { _ in
            // Registry update will already re-render via @ObservedObject;
            // also refresh cost in case the state change implies cost recorded.
            Task { await refreshCost() }
        }
    }

    private func refreshCost() async {
        let snap = await ledger.snapshot()
        let tier = await ledger.currentCapTier()
        await MainActor.run {
            self.costToday = snap
            self.costTier = tier
        }
    }

    // MARK: - Filters Pane

    private var filtersPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Filters")

            VStack(alignment: .leading, spacing: 6) {
                Text("Status").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Runtime").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $runtimeFilter) {
                    ForEach(RuntimeFilter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Repo").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $repoFilter) {
                    Text("All repos").tag(String?.none)
                    ForEach(allRepos, id: \.self) { repo in
                        Text(URL(fileURLWithPath: repo).lastPathComponent)
                            .tag(String?.some(repo))
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $modelFilter) {
                    Text("All models").tag(String?.none)
                    ForEach(allModels, id: \.self) { model in
                        Text(model).tag(String?.some(model))
                    }
                }
                .labelsHidden()
            }

            Spacer()

            // Counts summary footer
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                let c = registry.counts
                HStack(spacing: 8) {
                    countChip(label: "Running", value: c.running, color: .blue)
                    countChip(label: "Ready", value: c.ready, color: .green)
                    countChip(label: "Error", value: c.error, color: .red)
                }
                .font(.caption)
            }
        }
        .padding(16)
    }

    // MARK: - List Pane

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack {
                sectionHeader("Agents")
                Spacer()
                Text("\(filteredStates.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if filteredStates.isEmpty {
                emptyListPlaceholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredStates) { state in
                            agentRow(state)
                                .background(
                                    selectedRunId == state.run.id
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedRunId = state.run.id
                                }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var emptyListPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No agents match your filters")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Cursor agents will appear here once a run starts.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func agentRow(_ state: CursorAgentRegistryState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(for: state)
                .frame(width: 16, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(repoLabel(state.run.repoPath))
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text(costLabel(state.run.costCents))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(state.run.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(state.run.runtime.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(elapsedLabel(state.run))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            costBanner
            Divider()
            if let selected = selectedState {
                detailContent(for: selected)
            } else {
                detailEmptyPlaceholder
            }
        }
    }

    private var costBanner: some View {
        let total = costToday?.totalCents ?? 0
        let soft = CursorCostLedger.softCapCents()
        let hard = CursorCostLedger.hardCapCents()
        return HStack(spacing: 12) {
            Image(systemName: costBannerIcon)
                .foregroundStyle(costBannerColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(dollars(total))
                        .font(.callout)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text("of \(dollars(soft)) soft · \(dollars(hard)) hard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(costTierLabel)
                    .font(.caption2)
                    .foregroundStyle(costBannerColor)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(costBannerColor.opacity(0.08))
    }

    private var costBannerIcon: String {
        switch costTier {
        case .under: return "dollarsign.circle"
        case .soft: return "exclamationmark.triangle"
        case .hard: return "octagon"
        }
    }

    private var costBannerColor: Color {
        switch costTier {
        case .under: return .secondary
        case .soft: return .orange
        case .hard: return .red
        }
    }

    private var costTierLabel: String {
        switch costTier {
        case .under: return "Under cap"
        case .soft: return "Soft cap reached — cloud agents paused"
        case .hard: return "Hard cap reached — new runs blocked"
        }
    }

    private var detailEmptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.text.square")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select an agent")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Run details, timeline, and artifacts will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func detailContent(for state: CursorAgentRegistryState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detailHeader(state)
                detailKeyValueGrid(state)
                detailTimelineSection(state)
                detailArtifactsSection(state)
                if state.run.status == .running || state.run.status == .queued {
                    HStack {
                        Button(role: .destructive) {
                            // Stop wiring lives in Wave 5 (CursorRuntime.shared.agentCancel).
                            // Wave 4 ships the surface; the button is a no-op stub
                            // that logs the intent for now.
                            print("[CursorAgentsWindow] Stop requested for \(state.run.id) — wiring lands in Wave 5")
                        } label: {
                            Label("Stop Agent", systemImage: "stop.circle")
                        }
                        Spacer()
                    }
                }
            }
            .padding(20)
        }
    }

    private func detailHeader(_ state: CursorAgentRegistryState) -> some View {
        HStack(spacing: 10) {
            statusIcon(for: state)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(repoLabel(state.run.repoPath))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(state.run.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
        }
    }

    private func detailKeyValueGrid(_ state: CursorAgentRegistryState) -> some View {
        let cost = costLabel(state.run.costCents)
        let elapsed = elapsedLabel(state.run)
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                detailKey("Status")
                detailValue(state.run.status.rawValue)
            }
            GridRow {
                detailKey("Runtime")
                detailValue(state.run.runtime.rawValue)
            }
            GridRow {
                detailKey("Model")
                detailValue(state.run.model)
            }
            GridRow {
                detailKey("Started")
                detailValue(state.run.startedAt.formatted(date: .abbreviated, time: .standard))
            }
            GridRow {
                detailKey("Elapsed")
                detailValue(elapsed)
            }
            GridRow {
                detailKey("Cost")
                detailValue(cost)
            }
            if let err = state.lastErrorMessage {
                GridRow {
                    detailKey("Error")
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func detailKey(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    private func detailValue(_ s: String) -> some View {
        Text(s)
            .font(.callout)
            .textSelection(.enabled)
    }

    private func detailTimelineSection(_ state: CursorAgentRegistryState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timeline")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Wave 5 will render the real SSE event stream as structured chips
            // (Indexed/Read/Edit/Run/Tool/Error per UX spec).
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(.tertiary)
                Text("No events recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.06))
            .cornerRadius(6)
        }
    }

    private func detailArtifactsSection(_ state: CursorAgentRegistryState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Artifacts")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Wave 4 surfaces the PR URL artifact if the run has one;
            // Wave 5 will render the full artifact stream.
            if let prURL = state.run.prURL, !prURL.isEmpty,
               let url = URL(string: prURL) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Pull Request")
                    }
                    .font(.caption)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.tertiary)
                    Text("No artifacts yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.06))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Helpers

    private var allStates: [CursorAgentRegistryState] {
        registry.allStates
    }

    private var allRepos: [String] {
        let repos = Set(allStates.compactMap { $0.run.repoPath })
        return repos.sorted()
    }

    private var allModels: [String] {
        let models = Set(allStates.map { $0.run.model })
        return models.sorted()
    }

    private var filteredStates: [CursorAgentRegistryState] {
        allStates.filter { state in
            // Status filter
            switch statusFilter {
            case .all:
                break
            case .running:
                guard state.run.status == .running || state.run.status == .queued else { return false }
            case .ready:
                guard state.run.status == .succeeded else { return false }
            case .error:
                guard state.run.status == .failed || state.run.status == .cancelled || state.healthLevel == .red
                else { return false }
            case .completed:
                guard state.run.status == .succeeded || state.run.status == .failed || state.run.status == .cancelled
                else { return false }
            }
            // Runtime filter
            switch runtimeFilter {
            case .all: break
            case .local:
                guard state.run.runtime == .local else { return false }
            case .cloud:
                guard state.run.runtime == .cloud else { return false }
            }
            // Repo filter
            if let repo = repoFilter, state.run.repoPath != repo { return false }
            // Model filter
            if let model = modelFilter, state.run.model != model { return false }
            return true
        }
    }

    private var selectedState: CursorAgentRegistryState? {
        guard let id = selectedRunId else { return nil }
        return registry.state(for: id)
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func countChip(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value)")
                .monospacedDigit()
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    private func statusIcon(for state: CursorAgentRegistryState) -> some View {
        let symbol: String
        let color: Color
        if state.healthLevel == .red {
            symbol = "exclamationmark.triangle.fill"
            color = .red
        } else if state.healthLevel == .yellow {
            symbol = "clock.badge.exclamationmark"
            color = .orange
        } else {
            switch state.run.status {
            case .running, .queued:
                symbol = "play.circle.fill"
                color = .blue
            case .succeeded:
                symbol = "checkmark.circle.fill"
                color = .green
            case .failed:
                symbol = "xmark.circle.fill"
                color = .red
            case .cancelled:
                symbol = "minus.circle.fill"
                color = .secondary
            case .unknown:
                symbol = "questionmark.circle"
                color = .secondary
            }
        }
        return Image(systemName: symbol).foregroundStyle(color)
    }

    private func repoLabel(_ path: String?) -> String {
        guard let path = path, !path.isEmpty else { return "(no repo)" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func costLabel(_ cents: Int?) -> String {
        guard let cents = cents else { return "—" }
        return dollars(cents)
    }

    private func elapsedLabel(_ run: CursorRun) -> String {
        let end = run.endedAt ?? Date()
        let secs = max(0, Int(end.timeIntervalSince(run.startedAt)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }

    private func dollars(_ cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        return String(format: "$%.2f", dollars)
    }
}
