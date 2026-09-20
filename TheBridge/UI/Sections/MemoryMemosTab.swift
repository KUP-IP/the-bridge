// MemoryMemosTab.swift — Settings → Memory → Memos tab (2026-07-03 redesign)
// TheBridge · UI · Sections
//
// Twin master-detail port of the mockup's `MemosTab()` (design/the-bridge-design-
// system/project/pages/page-memory.jsx). Consolidates the old Process (cockpit) +
// Inbox (triage queue) + Processing-status concerns into one status-filtered pipeline:
// left column is a searchable, status-grouped memo list (240pt fixed); right column is
// a stacked-card detail pane (Title / Status / Transcript / Filed in Notion / Process
// this memo). Business logic — intent-row shaping, batch-commit ordering, checkable-tag
// rules, registry-picker sourcing — is untouched, delegated to `MemoryProcessCockpit` /
// `MemoryProcessBatchConfirm` / `MemoryProcessPreviewSession` exactly as the old
// MemoryProcessTab did. The old Inbox triage dispositions (VoiceMemoReviewResolver)
// are folded into a "Needs review" card in the detail pane instead of a separate tab.
//
// See memory-swiftui-uiiter-log.md for this implementation's 3-loop iteration history.

import SwiftUI
import AppKit
import MCP

public struct MemoryMemosTab: View {
    let initialFilter: MemorySection.InboxFilter
    let initialMemoId: String?

    public init(initialFilter: MemorySection.InboxFilter = .all, initialMemoId: String? = nil) {
        self.initialFilter = initialFilter
        self.initialMemoId = initialMemoId
    }

    // MARK: - List state

    @State private var memos: [VoiceMemoRecording] = []
    @State private var selectedId: String?
    @State private var searchText: String = ""
    @State private var statusFilter: StatusGroup.Filter = .all
    @State private var reasonFilter: MemorySection.InboxFilter = .all
    @State private var titleCache: [String: MemoTitle] = [:]
    @State private var reviewEntries: [VoiceMemoReviewEntry] = []
    @State private var awaitingAgentMemoIds: Set<String> = []
    @State private var didApplyInitialSelection = false

    // MARK: - Detail / cockpit state (ported 1:1 from MemoryProcessTab)

    @State private var transcript: String = ""
    @State private var plan: VoiceMemoPlan?
    @State private var overrideIntentId: String?
    @State private var activity: [MemoryHubActivityEvent] = []
    @State private var statusMessage: String?
    @State private var actionMessage: String?
    @State private var isLoading = false
    @State private var loadingLabel = "Loading preview…"
    @State private var titleDraft: String = ""
    @State private var cloudProvider: MemoryHubProvider?
    @State private var cloudBusy = false
    @State private var titleStatus: String?
    @State private var intentDiffBadges: [String: String] = [:]
    @State private var triageSessionActive = false
    @State private var resolvingReviewIds: Set<String> = []

    @State private var checkedIntentIds: Set<String> = []
    @State private var transcriptExpanded = false
    @State private var technicalDetailsOpen = false
    @State private var showFullTranscriptSheet = false
    @State private var selectedRowIdByIntentId: [String: String] = [:]
    @State private var pickerByIntentId: [String: CockpitPickerState] = [:]
    @State private var confirmPhase: ConfirmPhase = .idle
    @State private var batchOutcomes: [String: MemoryProcessBatchConfirm.BatchCommitOutcome] = [:]
    @State private var showRegistrySheet = false
    @State private var registrySheetRows: [CockpitIntentRow] = []

    private enum ConfirmPhase { case idle, running, done }

    /// Mockup's simpler top-level status grouping (All/Review/Active/Filed), the
    /// PRIMARY grouping per the task's reconciliation instruction. The old InboxFilter's
    /// reason-based filters (awaitingAgent/noTranscript/routingFailed/lowConfidence)
    /// become a secondary filter available specifically within the "Review" group.
    private enum StatusGroup: String, CaseIterable, Identifiable {
        case review, processing, filed, ready
        var id: String { rawValue }

        enum Filter: String, CaseIterable, Identifiable {
            case all, review, processing, filed
            var id: String { rawValue }
            var label: String {
                switch self {
                case .all: return "All"
                case .review: return "Review"
                case .processing: return "Active"
                case .filed: return "Filed"
                }
            }
        }

        var label: String {
            switch self {
            case .review: return "Needs review"
            case .processing: return "Processing"
            case .filed: return "Filed"
            case .ready: return "Ready"
            }
        }
    }

    // MARK: - Derived

    private var rows: [CockpitIntentRow] {
        guard let plan, let selectedId else { return [] }
        return MemoryProcessCockpit.intentRows(memoId: selectedId, plan: plan, overrideIntentId: overrideIntentId)
    }

    private var currentTitleDisplay: String? {
        if let memoId = selectedId, let cached = titleCache[memoId]?.title, !cached.isEmpty {
            return cached
        }
        return plan?.generatedTitle
    }

    private var confirmEnabled: Bool {
        confirmPhase == .idle
            && MemoryProcessBatchConfirm.canConfirm(checkedIds: checkedIntentIds, rows: rows)
    }

    private var selectedMemo: VoiceMemoRecording? {
        guard let selectedId else { return nil }
        return memos.first { $0.id == selectedId }
    }

    private var selectedReviewEntries: [VoiceMemoReviewEntry] {
        guard let selectedId else { return [] }
        return reviewEntries.filter { $0.memoId == selectedId }
    }

    /// Which status group a memo currently belongs to, mirroring the mockup's
    /// review/processing/filed/ready buckets. Derived from real state: review-queue
    /// membership, cached plan/committed outcomes, and whether it's still unprocessed.
    private func statusGroup(for memo: VoiceMemoRecording) -> StatusGroup {
        if awaitingAgentMemoIds.contains(memo.id) || reviewEntries.contains(where: { $0.memoId == memo.id }) {
            return .review
        }
        if memo.id == selectedId, isLoading {
            return .processing
        }
        if memo.id == selectedId, plan != nil, confirmPhase == .running {
            return .processing
        }
        if memo.id == selectedId, confirmPhase == .done,
           let result = batchOutcomes.values.first, result.ok {
            return .filed
        }
        return .ready
    }

    private func matchesSearch(_ memo: VoiceMemoRecording) -> Bool {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let q = searchText.lowercased()
        let display = MemoryHubMemoTitler.listDisplay(recording: memo, cached: titleCache[memo.id])
        if display.text.lowercased().contains(q) { return true }
        if let t = memo.transcript?.lowercased(), t.contains(q) { return true }
        return false
    }

    private func matchesReasonFilter(_ memo: VoiceMemoRecording) -> Bool {
        guard reasonFilter != .all else { return true }
        guard let entry = reviewEntries.first(where: { $0.memoId == memo.id }) else { return false }
        switch reasonFilter {
        case .all: return true
        case .awaitingAgent: return entry.effectiveReviewTag == .awaitingAgent
        case .noTranscript: return entry.effectiveReviewTag == .noTranscript
        case .routingFailed: return entry.effectiveReviewTag == .routingFailed
        case .lowConfidence: return entry.effectiveReviewTag == .lowConfidence
        }
    }

    private var visibleMemos: [VoiceMemoRecording] {
        memos.filter { memo in
            matchesSearch(memo)
                && (statusFilter == .all || statusGroup(for: memo).rawValue == statusFilter.rawValue)
                && (statusFilter != .review || matchesReasonFilter(memo))
        }
    }

    private var groupedMemos: [(group: StatusGroup, items: [VoiceMemoRecording])] {
        if statusFilter != .all {
            return [(StatusGroup(rawValue: statusFilter.rawValue) ?? .ready, visibleMemos)]
        }
        return StatusGroup.allCases.compactMap { g in
            let items = visibleMemos.filter { statusGroup(for: $0).rawValue == g.rawValue }
            return items.isEmpty ? nil : (g, items)
        }
    }

    private var reviewCount: Int { memos.filter { statusGroup(for: $0) == .review }.count }
    private var processingCount: Int { memos.filter { statusGroup(for: $0) == .processing }.count }

    // MARK: - Body

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            listColumn
                .frame(width: 240)
            Divider().background(BridgeTokens.hairlineFaint)
            VStack(spacing: 0) {
                if triageSessionActive, selectedId != nil {
                    triageBanner
                    Divider().background(BridgeTokens.hairlineFaint)
                }
                detailColumn
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            statusFilter = statusGroupFilter(for: initialFilter)
            if initialFilter != .all { reasonFilter = initialFilter }
            reloadMemos()
            reloadActivity()
            Task { await restorePreviewSessionIfNeeded() }
            Task { await refreshTriageBanner() }
        }
        .onChange(of: selectedId) { _, _ in
            Task { await refreshTriageBanner() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryHubLiveProcessingDidChange)) { _ in
            reloadActivity()
            reloadMemos()
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceMemoReviewDidChange)) { _ in
            reloadMemos()
        }
        .sheet(isPresented: $showRegistrySheet) {
            MemoryProcessRegistryConfigureSheet(
                rows: registrySheetRows,
                allRows: rows,
                selectedRowIdByIntentId: $selectedRowIdByIntentId,
                pickerByIntentId: $pickerByIntentId,
                onLoadPicker: { row in await loadPicker(for: row) },
                onSave: {
                    showRegistrySheet = false
                    persistPreviewSession()
                    Task { await runBatchConfirm() }
                },
                onCancel: { showRegistrySheet = false }
            )
        }
        .sheet(isPresented: $showFullTranscriptSheet) {
            fullTranscriptSheet
        }
    }

    private func statusGroupFilter(for inboxFilter: MemorySection.InboxFilter) -> StatusGroup.Filter {
        inboxFilter == .all ? .all : .review
    }

    // MARK: - Triage banner (agent-processing coordination — unchanged contract)

    private var triageBanner: some View {
        HStack(spacing: 10) {
            BridgeBadge("Agent triage active", tone: .info, showsDot: true)
            Text("Bridge executes commits — agent must not re-commit.")
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg3)
            Spacer(minLength: 8)
            BridgeButton("End session", systemImage: "xmark.circle") {
                if let memoId = selectedId {
                    MemoryHubTriageSessionBridge.endSession(memoId: memoId)
                }
                triageSessionActive = false
            }
            .accessibilityIdentifier(BridgeAXID.Memory.Process.triageEndSession)
        }
        .padding(.horizontal, BridgeTokens.Space.paneH)
        .padding(.vertical, 10)
        .background(BridgeTokens.accent.opacity(0.08))
        .accessibilityIdentifier(BridgeAXID.Memory.Process.triageBanner)
    }

    @MainActor
    private func refreshTriageBanner() async {
        guard let memoId = selectedId else {
            triageSessionActive = false
            return
        }
        triageSessionActive = await MemoryHubTriageSessionBridge.isActive(memoId: memoId)
    }

    // MARK: - Left column: search + filter pills + grouped list

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            listMetaRow
            listFilterPills
            listRows
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var listMetaRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // NOTE (Loop 2 P1 fix, memory-swiftui-uiiter-log.md): a bare inline
            // HStack does not give SwiftUI's AX bridge a distinct enough View
            // identity boundary — an .accessibilityIdentifier applied to it (even as
            // the outermost modifier, even after .accessibilityElement(children:
            // .contain)) still resolved to the section-wide root id in live testing.
            // The fix that actually works (matching MemoryRecallTab's
            // RecallSearchField precedent) is a dedicated View struct with the id
            // applied at the CALL SITE, not composed inline.
            MemosSearchField(query: $searchText)
                .accessibilityIdentifier(BridgeAXID.Memory.Memos.search)
                .accessibilityElement(children: .contain)
            Text("\(memos.count) total · \(reviewCount) need review · \(processingCount) processing")
                .font(BridgeTokens.Typeface.micro)
                .foregroundStyle(BridgeTokens.fg4)
                .lineLimit(1)
        }
        .padding(12)
    }

    private var listFilterPills: some View {
        BridgeSegmented(
            selection: $statusFilter,
            options: StatusGroup.Filter.allCases.map { ($0, $0.label) }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityIdentifier(BridgeAXID.Memory.Memos.filterBar)
        .overlay(alignment: .bottom) {
            if statusFilter == .review {
                reasonFilterRow
                    .offset(y: 34)
            }
        }
        .padding(.bottom, statusFilter == .review ? 34 : 0)
    }

    private var reasonFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MemorySection.InboxFilter.allCases, id: \.self) { filter in
                    let on = reasonFilter == filter
                    Button {
                        reasonFilter = filter
                    } label: {
                        Text(filter.label)
                            .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? BridgeTokens.fg1 : BridgeTokens.fg4)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background {
                                if on { Capsule().fill(BridgeTokens.accent.opacity(0.16)) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(BridgeAXID.Memory.inboxFilterBar + ".\(filter.rawValue)")
                }
            }
            .padding(.horizontal, 12)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.inboxFilterBar)
    }

    private var listRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(groupedMemos, id: \.group) { entry in
                    if statusFilter == .all {
                        groupCaption(entry.group, count: entry.items.count)
                    }
                    ForEach(entry.items) { memo in
                        memoRow(memo)
                    }
                }
                if visibleMemos.isEmpty {
                    emptyListState
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(BridgeAXID.Memory.Memos.list)
    }

    private func groupCaption(_ group: StatusGroup, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(group.label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(BridgeTokens.Typeface.trackCap)
                .textCase(.uppercase)
                .foregroundStyle(BridgeTokens.fg4)
            Text("\(count)")
                .font(BridgeTokens.Typeface.mono)
                .foregroundStyle(BridgeTokens.fg5)
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
        }
        .padding(.horizontal, 7)
        .padding(.top, 11)
        .padding(.bottom, 5)
    }

    private var emptyListState: some View {
        VStack(spacing: 4) {
            Text("No matches")
                .font(BridgeTokens.Typeface.body)
                .foregroundStyle(BridgeTokens.fg3)
            Text("Try a different filter or search term.")
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func memoRow(_ memo: VoiceMemoRecording) -> some View {
        let selected = selectedId == memo.id
        let display = MemoryHubMemoTitler.listDisplay(recording: memo, cached: titleCache[memo.id])
        let titleColor: Color = display.isPlaceholder
            ? BridgeTokens.fg4
            : (selected ? BridgeTokens.fg1 : BridgeTokens.fg2)
        let preview = (memo.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return Button {
            selectMemo(memo)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(BridgeTokens.wellFill).frame(width: 26, height: 26)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(display.text)
                            .font(BridgeTokens.Typeface.body)
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                        if display.intentCount > 1 {
                            Text("+\(display.intentCount - 1)")
                                .font(BridgeTokens.Typeface.micro)
                                .foregroundStyle(BridgeTokens.accent)
                        }
                        if awaitingAgentMemoIds.contains(memo.id) {
                            BridgeBadge(MemoryHubCockpitLabels.awaitingAgentLabel(), tone: .info)
                        }
                    }
                    if !preview.isEmpty {
                        Text(preview)
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.fg4)
                            .lineLimit(1)
                    }
                    Text(MemoryHubMemoTitler.humanizedDate(memo.recordedAt))
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? BridgeTokens.selectionFill : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? BridgeTokens.hairline : Color.clear, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.memoRow(memo.id))
    }

    private func selectMemo(_ memo: VoiceMemoRecording) {
        selectedId = memo.id
        overrideIntentId = nil
        confirmPhase = .idle
        batchOutcomes = [:]
        technicalDetailsOpen = false
        transcriptExpanded = false
        Task { await loadInspect(for: memo, forceRefresh: false) }
    }

    // MARK: - Right column: detail pane

    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                if let actionMessage {
                    Text(actionMessage)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                if isLoading {
                    ProgressView(loadingLabel)
                } else if let memo = selectedMemo {
                    titleCard
                    statusCard
                    transcriptCard
                    if let notionURL = filedNotionURL {
                        filedInNotionCard(url: notionURL)
                    }
                    if !selectedReviewEntries.isEmpty {
                        needsReviewCard
                    }
                    processCard(memo: memo)
                } else {
                    Text("Select a memo to preview and commit intents.")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                }
            }
            .padding(BridgeTokens.Space.paneH)
            .padding(.vertical, BridgeTokens.Space.paneV)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.centerPane)
    }

    // MARK: - Title card

    private var titleCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Title")
                HStack(spacing: 8) {
                    BridgeInput("Memo title", text: $titleDraft)
                        .accessibilityIdentifier(BridgeAXID.Memory.Process.titleRename)
                        .onSubmit { saveRename() }
                    BridgeButton("Rename", systemImage: "pencil", variant: .primary) { saveRename() }
                    if let provider = cloudProvider, MemoryHubProviderConfigStore.canRunCloud(provider) {
                        BridgeButton("Improve title", systemImage: "sparkles", isEnabled: !cloudBusy) {
                            Task { await improveTitleViaCloud(provider: provider) }
                        }
                        .accessibilityIdentifier(BridgeAXID.Memory.Process.titleCloud)
                    }
                    if cloudBusy { ProgressView().controlSize(.small) }
                }
                if let titleStatus {
                    Text(titleStatus)
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                }
            }
        }
    }

    // MARK: - Status card (plain-language stepper, replaces MemSteps)

    /// Plain-language pipeline steps derived from real state — mirrors the mockup's
    /// MemSteps (Transcribed → Summarized → Filed/Blocked), but computed from the
    /// actual transcript/plan/confirm state instead of a fixture.
    private var statusSteps: [(label: String, state: StepState)] {
        guard let memo = selectedMemo else { return [] }
        let transcribed: StepState = memo.hasTranscript || !transcript.isEmpty ? .done : .active
        var summarized: StepState = .pending
        var final: (label: String, state: StepState) = ("Ready to file", .pending)

        if plan != nil {
            summarized = .done
            if confirmPhase == .done {
                let anySuccess = batchOutcomes.values.contains { $0.ok }
                let anyManual = batchOutcomes.values.contains { $0.needsManual }
                if anySuccess {
                    final = ("Filed to Notion", .done)
                } else if anyManual {
                    final = ("Blocked — needs manual commit", .blocked)
                } else {
                    final = ("Blocked — commit failed", .blocked)
                }
            } else if confirmPhase == .running {
                final = ("Committing…", .active)
            } else if !selectedReviewEntries.isEmpty {
                final = ("Blocked — needs review", .blocked)
            } else {
                final = ("Ready to file", .active)
            }
        } else if isLoading {
            summarized = .active
            final = ("Awaiting result", .pending)
        }
        return [
            ("Transcribed", transcribed),
            ("Summarized", summarized),
            final,
        ]
    }

    private enum StepState { case done, active, blocked, pending }

    private var statusCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Status")
                statusStepper
                if let rejectReason = blockedReason {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(BridgeTokens.warn)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rejectReason)
                                .font(BridgeTokens.Typeface.sub)
                                .foregroundStyle(BridgeTokens.fg2)
                            Text("This memo is queued for review and was never marked processed.")
                                .font(BridgeTokens.Typeface.meta)
                                .foregroundStyle(BridgeTokens.fg4)
                        }
                    }
                    .padding(10)
                    .background(BridgeTokens.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                technicalDetailsDisclosure
            }
        }
        // NOTE (Loop 1 P1 fix, memory-swiftui-uiiter-log.md): do NOT put an
        // .accessibilityIdentifier on this outer BridgeGlassCard — it shadows every
        // descendant control's own id in the raw AX tree (the same hazard already
        // caught in MemorySettingsTab Loop 1 / MemoryRecallTab Loop 1). The
        // Technical-details toggle/body below carry their own distinct ids; no
        // card-level id is needed for automation to find this card.
    }

    private var blockedReason: String? {
        guard !selectedReviewEntries.isEmpty else { return nil }
        return selectedReviewEntries.first?.reason
    }

    private var statusStepper: some View {
        HStack(spacing: 7) {
            ForEach(Array(statusSteps.enumerated()), id: \.offset) { idx, step in
                HStack(spacing: 6) {
                    Circle()
                        .fill(stepColor(step.state))
                        .frame(width: 7, height: 7)
                    Text(step.label)
                        .font(.system(size: 12.5, weight: step.state == .active || step.state == .blocked ? .semibold : .medium))
                        .foregroundStyle(stepTextColor(step.state))
                }
                if idx < statusSteps.count - 1 {
                    Rectangle().fill(BridgeTokens.hairlineStrong).frame(width: 13, height: 0.5)
                }
            }
        }
        .accessibilityIdentifier(BridgeAXID.Memory.Memos.statusStepper)
    }

    private func stepColor(_ state: StepState) -> Color {
        switch state {
        case .done: return BridgeTokens.ok
        case .active: return BridgeTokens.accentStrong
        case .blocked: return BridgeTokens.bad
        case .pending: return BridgeTokens.fg5
        }
    }

    private func stepTextColor(_ state: StepState) -> Color {
        switch state {
        case .done: return BridgeTokens.fg3
        case .active: return BridgeTokens.infoText
        case .blocked: return BridgeTokens.badText
        case .pending: return BridgeTokens.fg5
        }
    }

    private var technicalDetailsDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                technicalDetailsOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: technicalDetailsOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("Technical details")
                        .font(BridgeTokens.Typeface.sub)
                }
                .foregroundStyle(BridgeTokens.fg4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(BridgeAXID.Memory.Memos.technicalDetailsToggle)

            if technicalDetailsOpen {
                VStack(alignment: .leading, spacing: 3) {
                    if let plan {
                        Text(MemoryHubCockpitLabels.provenanceBadge(plan.provenance, degraded: plan.degraded))
                            .font(BridgeTokens.Typeface.mono)
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                    let memoId = selectedId
                    ForEach(activity.filter { $0.memoId == memoId }.prefix(12)) { event in
                        Text("\(event.phase.rawValue) · \(event.status) · \(event.receiptHashShort)")
                            .font(BridgeTokens.Typeface.mono)
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                    if activity.filter({ $0.memoId == memoId }).isEmpty {
                        Text("No receipts yet for this memo.")
                            .font(BridgeTokens.Typeface.mono)
                            .foregroundStyle(BridgeTokens.fg5)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier(BridgeAXID.Memory.Memos.technicalDetailsBody)
            }
        }
    }

    // MARK: - Transcript card (peek + sheet expand)

    private var transcriptCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Transcript")
                if transcript.isEmpty {
                    Text(MemoryHubCockpitLabels.unresolvedTranscriptMessage())
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                } else {
                    Text(transcript)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg2)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BridgeButton("Show full transcript", systemImage: "arrow.up.left.and.arrow.down.right") {
                        showFullTranscriptSheet = true
                    }
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.transcriptExpand)
                }
            }
        }
    }

    private var fullTranscriptSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(currentTitleDisplay ?? "Transcript")
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg1)
                Spacer()
                BridgeButton("Close", systemImage: "xmark") {
                    showFullTranscriptSheet = false
                }
                .accessibilityIdentifier(BridgeAXID.Memory.Process.transcriptCollapse)
            }
            .padding(14)
            Divider().background(BridgeTokens.hairlineFaint)
            ScrollView {
                Text(transcript)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(BridgeTokens.bgCanvas)
    }

    // MARK: - Filed in Notion card

    /// Best-effort Notion page URL parsed from a successful commit outcome's detail
    /// text. `voice_memo_commit` does not return a structured URL field today, so this
    /// stays conditional rather than fabricating a link — the card only appears when a
    /// real `notion.so` URL is present in the receipt.
    private var filedNotionURL: URL? {
        for outcome in batchOutcomes.values where outcome.ok {
            if let url = extractNotionURL(from: outcome.detail) { return url }
        }
        return nil
    }

    private func extractNotionURL(from text: String) -> URL? {
        guard let range = text.range(of: #"https://(www\.)?notion\.so/\S+"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(text[range]))
    }

    private func filedInNotionCard(url: URL) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Filed in Notion")
                BridgeButton("Open in Notion", variant: .link) {
                    NSWorkspace.shared.open(url)
                }
                .accessibilityIdentifier(BridgeAXID.Memory.notionOpen)
            }
        }
    }

    // MARK: - Needs review card (old Inbox row actions, folded into detail pane)

    private var needsReviewCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("Needs review")
                    Spacer()
                    BridgeBadge("\(selectedReviewEntries.count)", tone: .warn, showsDot: true)
                }
                ForEach(selectedReviewEntries) { entry in
                    reviewEntryRow(entry)
                }
            }
        }
        // NOTE (Loop 2 P1 fix, memory-swiftui-uiiter-log.md): deliberately no
        // .accessibilityIdentifier on this outer BridgeGlassCard — it would shadow
        // every descendant row's own action-button ids (addReminder/agentRemember/
        // retryRouting/markHandled/fileAsMemory/dismiss), the same hazard already
        // caught and fixed in MemorySettingsTab Loop 1 / MemoryRecallTab Loop 1 /
        // this file's own Loop 1. Each row's buttons stay individually locatable via
        // their own ids (shared across rows by design — same convention as the old
        // Inbox tab's `inboxRow`/`dismiss` ids — disambiguate by which memo is
        // selected, since only one memo's review entries render at a time).
    }

    private func reviewEntryRow(_ entry: VoiceMemoReviewEntry) -> some View {
        let resolving = resolvingReviewIds.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text(entry.reason)
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("\(entry.intentKind) · \(Int(entry.confidence * 100))%")
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
                if resolving { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                if let path = entry.memoPath, !path.isEmpty {
                    BridgeButton("Reveal in Finder", systemImage: "folder") {
                        revealInFinder(path: path)
                    }
                    .accessibilityIdentifier(BridgeAXID.Memory.revealInFinder)
                }
                Spacer(minLength: 0)
                BridgeButton("Add reminder", variant: .link) {
                    resolveEntry(entry, action: .reminder)
                }
                .accessibilityIdentifier(BridgeAXID.Memory.addReminder)
                BridgeButton("Agent should know", variant: .link) {
                    resolveEntry(entry, action: .agentRemember)
                }
                .accessibilityIdentifier(BridgeAXID.Memory.agentRemember)
                BridgeButton("Retry routing", variant: .link) {
                    resolveEntry(entry, action: .retryRouting)
                }
                .accessibilityIdentifier(BridgeAXID.Memory.retryRouting)
                BridgeButton("Mark handled", variant: .link) {
                    resolveEntry(entry, action: .markHandled)
                }
                .accessibilityIdentifier(BridgeAXID.Memory.markHandled)
                BridgeButton("File as Memory", variant: .link) {
                    resolveEntry(entry, action: .memoryKeep)
                }
                .accessibilityIdentifier(BridgeAXID.Memory.fileAsMemory)
                BridgeButton("Dismiss", variant: .default) {
                    dismissEntry(entry)
                }
                .accessibilityIdentifier(BridgeAXID.Memory.dismiss)
            }
        }
        .padding(.vertical, 4)
        .disabled(resolving)
    }

    // MARK: - Process this memo card

    private func processCard(memo: VoiceMemoRecording) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Process this memo")
                if plan == nil {
                    Text("Choose how to run Understand — intents appear after processing completes.")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                    HStack(spacing: 10) {
                        BridgeButton("Process with rules", systemImage: "cpu", variant: .primary) {
                            Task { await runUnderstand(for: memo, forceRefresh: false, provider: "heuristics") }
                        }
                        .accessibilityIdentifier(BridgeAXID.Memory.Process.processLocal)
                        if let cloudProvider, MemoryHubProviderConfigStore.canRunCloud(cloudProvider) {
                            BridgeButton("Process with cloud", systemImage: "cloud", variant: .primary) {
                                Task { await runUnderstand(for: memo, forceRefresh: false, provider: "cloud") }
                            }
                            .accessibilityIdentifier(BridgeAXID.Memory.Process.processCloud)
                        } else {
                            Text("Link a cloud provider in Settings to enable cloud Understand.")
                                .font(BridgeTokens.Typeface.meta)
                                .foregroundStyle(BridgeTokens.fg4)
                        }
                    }
                } else {
                    intentTagsSection(plan: plan!)
                    confirmSummaryStrip
                    confirmButtonBlock
                }
                Divider().background(BridgeTokens.hairlineFaint)
                HStack(spacing: 8) {
                    BridgeButton("Dry-run", systemImage: "play") {
                        Task { await runDryRun() }
                    }
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.dryRun)
                    BridgeButton("Re-run Understand", systemImage: "arrow.clockwise") {
                        MemoryHubTriageSessionBridge.invalidateForMemo(memoId: memo.id)
                        confirmPhase = .idle
                        batchOutcomes = [:]
                        Task { await runUnderstand(for: memo, forceRefresh: true, provider: nil) }
                    }
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.refreshPreview)
                    if let cloudProvider, MemoryHubProviderConfigStore.canRunCloud(cloudProvider) {
                        BridgeButton("Improve title", systemImage: "sparkles", isEnabled: !cloudBusy) {
                            Task { await improveTitleViaCloud(provider: cloudProvider) }
                        }
                    }
                }
            }
        }
        // NOTE (Loop 1 P1 fix, memory-swiftui-uiiter-log.md): do NOT put an
        // .accessibilityIdentifier on this outer BridgeGlassCard — confirmed via live
        // ax_inspect evidence that it shadows every descendant button's own id
        // (processLocal/processCloud/dryRun/refreshPreview all resolved to this one
        // shared id instead of their own). Same hazard already fixed twice elsewhere
        // in this log (MemorySettingsTab Loop 1, MemoryRecallTab Loop 1).
    }

    private func intentTagsSection(plan: VoiceMemoPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                BridgeCardLabel("Intents")
                Spacer()
                BridgeBadge(
                    MemoryHubCockpitLabels.provenanceBadge(plan.provenance, degraded: plan.degraded),
                    tone: plan.degraded ? .warn : .neutral
                )
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(rows) { row in
                    intentTagChip(row)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(BridgeAXID.Memory.Process.intentTags)
        }
    }

    @ViewBuilder
    private func intentTagChip(_ row: CockpitIntentRow) -> some View {
        let checkable = MemoryProcessBatchConfirm.isTagCheckable(row)
        let checked = checkedIntentIds.contains(row.intentId)
        let locked = confirmPhase != .idle
        let outcome = batchOutcomes[row.intentId]
        let expanded = expandedIntentIds.contains(row.intentId)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if checkable {
                    Toggle(isOn: Binding(
                        get: { checkedIntentIds.contains(row.intentId) },
                        set: { on in
                            if on { checkedIntentIds.insert(row.intentId) }
                            else { checkedIntentIds.remove(row.intentId) }
                            persistPreviewSession()
                        }
                    )) {
                        Text(MemoryProcessCockpit.tagLabel(for: row))
                            .font(BridgeTokens.Typeface.meta)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(locked)
                } else {
                    Text(MemoryProcessCockpit.tagLabel(for: row))
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                    Text("(review)")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.warn)
                }
                Button {
                    if expanded { expandedIntentIds.remove(row.intentId) }
                    else { expandedIntentIds.insert(row.intentId) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse write preview" : "Expand write preview")
                if confirmPhase == .running, checked {
                    ProgressView().controlSize(.small)
                } else if let outcome {
                    Image(systemName: outcome.ok ? "checkmark.circle.fill" : (outcome.needsManual ? "exclamationmark.circle" : "xmark.circle"))
                        .foregroundStyle(outcome.ok ? BridgeTokens.ok : BridgeTokens.warn)
                        .font(.system(size: 11))
                }
                if let diff = intentDiffBadges[row.intentId] {
                    BridgeBadge(MemoryHubCockpitLabels.diffBadgeLabel(diff), tone: .info)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(checkable && checked ? BridgeTokens.accent.opacity(0.12) : BridgeTokens.wellFill)
            }
            .accessibilityIdentifier(BridgeAXID.Memory.Process.intentTagCheckbox(row.intentId))
            if expanded {
                intentInspectorBlock(row: row, plan: plan!)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.intentInspector(row.intentId))
            }
        }
    }

    @State private var expandedIntentIds: Set<String> = []

    private func intentInspectorBlock(row: CockpitIntentRow, plan: VoiceMemoPlan) -> some View {
        let lines = MemoryProcessCockpit.intentWritePreview(for: row, plan: plan)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(line.label + ":")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                        .frame(width: 120, alignment: .leading)
                    Text(line.value)
                        .font(BridgeTokens.Typeface.mono)
                        .foregroundStyle(BridgeTokens.fg2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.top, 4)
        .padding(.leading, 8)
    }

    @ViewBuilder
    private var confirmSummaryStrip: some View {
        if let plan {
            let lines = MemoryProcessBatchConfirm.confirmSummaryLines(checkedIds: checkedIntentIds, rows: rows, plan: plan)
            if !lines.isEmpty {
                BridgeGlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        BridgeCardLabel("Confirm preview")
                        ForEach(lines, id: \.intentId) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.label)
                                    .font(BridgeTokens.Typeface.meta)
                                    .foregroundStyle(BridgeTokens.fg3)
                                Text(line.preview)
                                    .font(BridgeTokens.Typeface.mono)
                                    .foregroundStyle(BridgeTokens.fg2)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
                .accessibilityIdentifier(BridgeAXID.Memory.Process.confirmSummary)
            }
        }
    }

    private var confirmButtonBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            BridgeButton("Confirm", systemImage: "checkmark.seal", variant: .primary, isEnabled: confirmEnabled) {
                onConfirmTapped()
            }
            .accessibilityIdentifier(BridgeAXID.Memory.Process.confirmButton)
            if confirmPhase == .idle, !confirmEnabled,
               let reason = MemoryProcessBatchConfirm.confirmDisabledReason(checkedIds: checkedIntentIds, rows: rows) {
                Text(reason)
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
            }
        }
    }

    private func onConfirmTapped() {
        let missing = MemoryProcessBatchConfirm.missingRegistryConfiguration(
            checkedIds: checkedIntentIds,
            rows: rows,
            selectedRowIdByIntentId: selectedRowIdByIntentId
        )
        if !missing.isEmpty {
            registrySheetRows = missing
            showRegistrySheet = true
            return
        }
        Task { await runBatchConfirm() }
    }

    // MARK: - Data loading

    private func reloadMemos() {
        memos = VoiceMemoProcessor.listUnprocessed()
        titleCache = MemoryHubMemoTitleStore.load()
        reviewEntries = VoiceMemoReviewStore.pendingEntries()
        awaitingAgentMemoIds = Set(
            reviewEntries
                .filter { $0.effectiveReviewTag == .awaitingAgent }
                .map(\.memoId)
        )
        MemoryReviewBadgeCounter.shared.refresh()
        applyInitialSelectionIfNeeded()
    }

    private func applyInitialSelectionIfNeeded() {
        guard !didApplyInitialSelection else { return }
        guard let initialMemoId, let memo = memos.first(where: { $0.id == initialMemoId }) else { return }
        didApplyInitialSelection = true
        selectMemo(memo)
    }

    private func reloadActivity() {
        MemoryHubActivityLog.repairScan()
        activity = MemoryHubActivityLog.recent(limit: 50)
    }

    @MainActor
    private func loadInspect(for memo: VoiceMemoRecording, forceRefresh: Bool) async {
        await MemoryProcessPreviewSession.shared.setLastSelectedMemoId(memo.id)

        if !forceRefresh, let cached = await cachedBundle(for: memo) {
            applyBundle(cached)
            return
        }

        isLoading = true
        loadingLabel = "Loading memo…"
        statusMessage = MemoryHubCockpitLabels.selectStatus(hasTranscript: memo.hasTranscript)
        defer { isLoading = false }

        cloudProvider = MemoryHubProviderConfigStore.load().first
        titleDraft = MemoryHubMemoTitler.listDisplay(recording: memo, cached: titleCache[memo.id]).text
        titleCache[memo.id] = MemoryHubMemoTitleStore.title(for: memo.id)

        guard let router = await LiveToolRouter.shared.current() else {
            statusMessage = "MCP server not ready."
            return
        }
        do {
            let result = try await router.dispatch(toolName: "voice_memo_get", arguments: .object([
                "memoId": .string(memo.id),
                "understand": .bool(false),
            ]))
            guard case .object(let envelope) = result,
                  case .object(let memoObj) = envelope["memo"],
                  case .string(let t) = memoObj["transcript"] else {
                statusMessage = "Could not parse inspect."
                return
            }
            transcript = t
            plan = nil
            checkedIntentIds = []
            expandedIntentIds = []
            confirmPhase = .idle
            batchOutcomes = [:]
            statusMessage = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? MemoryHubCockpitLabels.unresolvedTranscriptMessage()
                : nil
            persistPreviewSession()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runUnderstand(for memo: VoiceMemoRecording, forceRefresh: Bool, provider: String?) async {
        await MemoryProcessPreviewSession.shared.setLastSelectedMemoId(memo.id)
        if forceRefresh {
            await MemoryProcessPreviewSession.shared.invalidate(memoId: memo.id)
        }

        isLoading = true
        loadingLabel = provider == "cloud" ? "Understanding (cloud)…" : (provider == "heuristics" ? "Understanding (rules)…" : "Understanding…")
        defer { isLoading = false }
        reloadActivity()

        guard let router = await LiveToolRouter.shared.current() else {
            statusMessage = "MCP server not ready."
            return
        }
        var args: [String: Value] = [
            "memoId": .string(memo.id),
            "understand": .bool(true),
        ]
        if let provider { args["provider"] = .string(provider) }
        do {
            let result = try await router.dispatch(toolName: "voice_memo_get", arguments: .object(args))
            guard case .object(let envelope) = result,
                  case .object(let memoObj) = envelope["memo"],
                  case .string(let t) = memoObj["transcript"],
                  case .object(let planObj) = envelope["plan"] else {
                statusMessage = "Could not parse Understand result."
                return
            }
            transcript = t
            statusMessage = nil
            let parsedPlan = parsePlan(from: planObj)
            plan = parsedPlan
            reloadPlanDiffBadges(memoId: memo.id)
            let title = MemoryHubMemoTitler.heuristicTitle(plan: parsedPlan, transcript: t)
            MemoryHubMemoTitleStore.put(title, memoId: memo.id)
            titleCache[memo.id] = MemoryHubMemoTitleStore.title(for: memo.id)
            titleDraft = MemoryHubMemoTitler.listDisplay(recording: memo, cached: titleCache[memo.id]).text
            cloudProvider = MemoryHubProviderConfigStore.load().first
            seedCheckedIntentsFromPlan()
            persistPreviewSession()
            reloadActivity()
            if MemoryHubMemoTitler.localTitleEnabled() {
                let memoId = memo.id
                Task {
                    if let upgraded = await MemoryHubMemoTitler.enhanceWithLocalTitle(
                        memoId: memoId, transcript: t, fallbackTitle: title.title) {
                        await MainActor.run { titleCache[memoId] = upgraded }
                    }
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func seedCheckedIntentsFromPlan() {
        let currentRows = rows
        checkedIntentIds = MemoryProcessBatchConfirm.defaultCheckedIntentIds(rows: currentRows)
    }

    @MainActor
    private func restorePreviewSessionIfNeeded() async {
        guard selectedId == nil,
              initialMemoId == nil,
              let memoId = await MemoryProcessPreviewSession.shared.lastSelectedMemoId,
              let memo = memos.first(where: { $0.id == memoId }) else { return }
        selectedId = memoId
        await loadInspect(for: memo, forceRefresh: false)
    }

    @MainActor
    private func cachedBundle(for memo: VoiceMemoRecording) async -> MemoryProcessPreviewBundle? {
        let fp = MemoryProcessPreviewSession.transcriptFingerprint(memo.transcript ?? "")
        if let hit = await MemoryProcessPreviewSession.shared.get(memoId: memo.id, transcriptFingerprint: fp) {
            return hit
        }
        let listEmpty = memo.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if listEmpty {
            return await MemoryProcessPreviewSession.shared.getIfPresent(memoId: memo.id)
        }
        return nil
    }

    @MainActor
    private func applyBundle(_ bundle: MemoryProcessPreviewBundle) {
        transcript = bundle.transcript
        plan = bundle.plan
        overrideIntentId = bundle.overrideIntentId
        intentDiffBadges = bundle.intentDiffBadges
        transcriptExpanded = bundle.transcriptExpanded
        selectedRowIdByIntentId = bundle.selectedRowIdByIntentId
        pickerByIntentId = bundle.pickerByIntentId
        if bundle.checkedIntentIds.isEmpty {
            seedCheckedIntentsFromPlan()
        } else {
            checkedIntentIds = Set(bundle.checkedIntentIds)
        }
        if let draft = bundle.titleDraft { titleDraft = draft }
        if let legacyRow = bundle.selectedRowId, let legacyIntent = bundle.selectedIntentId {
            selectedRowIdByIntentId[legacyIntent] = legacyRow
        }
        if let legacyPicker = bundle.picker, let legacyIntent = bundle.selectedIntentId {
            pickerByIntentId[legacyIntent] = legacyPicker
        }
        statusMessage = bundle.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? MemoryHubCockpitLabels.unresolvedTranscriptMessage()
            : nil
        if let memoId = selectedId {
            titleCache[memoId] = MemoryHubMemoTitleStore.title(for: memoId)
            cloudProvider = MemoryHubProviderConfigStore.load().first
        }
        confirmPhase = .idle
        batchOutcomes = [:]
    }

    @MainActor
    private func persistPreviewSession() {
        guard let memoId = selectedId, let plan else { return }
        let bundle = MemoryProcessPreviewBundle(
            memoId: memoId,
            transcript: transcript,
            transcriptFingerprint: MemoryProcessPreviewSession.transcriptFingerprint(transcript),
            plan: plan,
            selectedIntentId: nil,
            overrideIntentId: overrideIntentId,
            intentDiffBadges: intentDiffBadges,
            picker: nil,
            selectedRowId: nil,
            titleDraft: titleDraft,
            checkedIntentIds: Array(checkedIntentIds),
            transcriptExpanded: transcriptExpanded,
            selectedRowIdByIntentId: selectedRowIdByIntentId,
            pickerByIntentId: pickerByIntentId
        )
        Task { await MemoryProcessPreviewSession.shared.put(bundle) }
    }

    private func reloadPlanDiffBadges(memoId: String) {
        let snaps = MemoryHubPlanSnapshotStore.load(memoId: memoId)
        guard let heuristic = snaps.last(where: { $0.provenance == .heuristic }),
              let enhanced = snaps.filter({ $0.isEnhanced }).max(by: { $0.version < $1.version }) else {
            intentDiffBadges = [:]
            return
        }
        intentDiffBadges = MemoryHubPlanSnapshotStore.diffBadges(from: heuristic, to: enhanced)
    }

    @MainActor
    private func saveRename() {
        guard let memoId = selectedId else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let prior = titleCache[memoId]
        let edited = MemoTitle(
            title: trimmed,
            provenance: .edited,
            intentCount: prior?.intentCount ?? 0,
            transcriptHash: prior?.transcriptHash,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
        MemoryHubMemoTitleStore.put(edited, memoId: memoId)
        titleCache[memoId] = MemoryHubMemoTitleStore.title(for: memoId)
        titleStatus = "Renamed."
        persistPreviewSession()
    }

    @MainActor
    private func improveTitleViaCloud(provider: MemoryHubProvider) async {
        guard let memoId = selectedId, !cloudBusy else { return }
        cloudBusy = true
        titleStatus = "Improving title via cloud…"
        defer { cloudBusy = false }
        do {
            let updated = try await MemoryHubCloudTitler.improve(
                memoId: memoId, transcript: transcript, provider: provider)
            titleCache[memoId] = updated
            titleDraft = updated.title
            titleStatus = "Title updated (cloud)."
        } catch {
            titleStatus = "Cloud title unavailable — kept the current title."
        }
    }

    @MainActor
    private func loadPicker(for row: CockpitIntentRow) async {
        guard let entity = row.entityKey else { return }
        guard let router = await LiveToolRouter.shared.current() else {
            pickerByIntentId[row.intentId] = MemoryProcessCockpit.picker(entity: entity, liveRows: nil, sourceError: "MCP server not ready")
            return
        }
        do {
            let result = try await router.dispatch(toolName: "registry_list", arguments: .object([
                "entity": .string(entity), "limit": .int(100),
            ]))
            guard case .object(let env) = result, case .array(let rawRows)? = env["rows"] else {
                pickerByIntentId[row.intentId] = MemoryProcessCockpit.picker(entity: entity, liveRows: nil, sourceError: "registry_list empty")
                return
            }
            let liveRows: [MemoryHubRegistryRow] = rawRows.compactMap { r in
                guard case .object(let o) = r, case .string(let id)? = o["id"], case .string(let title)? = o["title"] else { return nil }
                return MemoryHubRegistryRow(id: id, title: title)
            }
            pickerByIntentId[row.intentId] = MemoryProcessCockpit.picker(entity: entity, liveRows: liveRows)
            persistPreviewSession()
        } catch {
            pickerByIntentId[row.intentId] = MemoryProcessCockpit.picker(entity: entity, liveRows: nil, sourceError: error.localizedDescription)
        }
    }

    @MainActor
    private func runDryRun() async {
        guard let memoId = selectedId else { return }
        guard let router = await LiveToolRouter.shared.current() else {
            statusMessage = "MCP server not ready."
            return
        }
        do {
            let result = try await router.dispatch(toolName: "voice_memo_process", arguments: .object([
                "memoId": .string(memoId), "mode": .string("single"), "dryRun": .bool(true),
            ]))
            if case .object(let env) = result, case .string(let summary)? = env["summary"] {
                statusMessage = summary
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runBatchConfirm() async {
        guard let memoId = selectedId else { return }
        guard let router = await LiveToolRouter.shared.current() else {
            statusMessage = "MCP server not ready."
            return
        }
        let ordered = MemoryProcessBatchConfirm.commitOrder(checkedIds: checkedIntentIds, rows: rows)
        guard !ordered.isEmpty else { return }

        confirmPhase = .running
        batchOutcomes = [:]
        var lastReceiptHash: String?
        var finalOutcomes: [MemoryProcessBatchConfirm.BatchCommitOutcome] = []

        let outcomes = await MemoryProcessBatchConfirm.executeBatch(
            memoId: memoId,
            checkedIds: checkedIntentIds,
            rows: rows,
            selectedRowIdByIntentId: selectedRowIdByIntentId
        ) { row, args in
            let result = try await router.dispatch(toolName: "voice_memo_commit", arguments: .object(args))
            guard case .object(let env) = result else { return [:] }
            return env
        }

        for outcome in outcomes {
            let row = ordered.first { $0.intentId == outcome.intentId }!
            if outcome.needsManual { statusMessage = "Manual commit needed: \(outcome.detail)" }
            let event = MemoryHubActivityEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                memoId: memoId, intentId: row.intentId, phase: .execute,
                action: "voice_memo_commit:\(row.kind.rawValue)",
                status: outcome.ok ? "executed" : (outcome.needsManual ? "manual" : "failed"),
                provenance: overrideIntentId != nil ? "override" : "election",
                actor: "operator", detail: String(outcome.detail.prefix(160))
            )
            try? MemoryHubActivityLog.append(event)
            let receiptHash = event.receiptHash
            if outcome.ok { lastReceiptHash = receiptHash }
            batchOutcomes[row.intentId] = MemoryProcessBatchConfirm.BatchCommitOutcome(
                intentId: outcome.intentId, kind: outcome.kind, ok: outcome.ok,
                needsManual: outcome.needsManual, detail: outcome.detail, receiptHash: receiptHash
            )
            finalOutcomes.append(batchOutcomes[row.intentId]!)
        }

        reloadActivity()
        reloadMemos()
        let memoStillListed = memos.contains { $0.id == memoId }
        let gateClear = VoiceMemoProcessedGate.noPendingReview(memoId: memoId)
        let processedGateCleared = gateClear && !memoStillListed

        let result = MemoryProcessBatchConfirm.BatchCommitResult(
            outcomes: finalOutcomes, processedGateCleared: processedGateCleared
        )
        statusMessage = MemoryProcessBatchConfirm.aggregateStatusMessage(result: result)
        confirmPhase = .done

        if result.anySuccess {
            MemoryHubTriageSessionBridge.emitCommitted(
                memoId: memoId,
                receiptHash: lastReceiptHash ?? "",
                detail: MemoryProcessBatchConfirm.triageCommittedDetail(result: result)
            )
            triageSessionActive = false
        }

        if processedGateCleared {
            await MemoryProcessPreviewSession.shared.remove(memoId: memoId)
            if !memos.contains(where: { $0.id == memoId }) {
                plan = nil
                transcript = ""
                checkedIntentIds = []
                selectedRowIdByIntentId = [:]
                pickerByIntentId = [:]
                selectedId = nil
            }
        } else {
            persistPreviewSession()
        }
    }

    // MARK: - Needs-review row actions (ported from the old Inbox tab)

    private func dismissEntry(_ entry: VoiceMemoReviewEntry) {
        do {
            guard try VoiceMemoReviewStore.dismiss(id: entry.id) else {
                actionMessage = "Entry not found."
                return
            }
            actionMessage = nil
            reloadMemos()
            NotificationCenter.default.post(name: .voiceMemoReviewDidChange, object: nil)
        } catch {
            actionMessage = "Dismiss failed: \(error.localizedDescription)"
        }
    }

    private func resolveEntry(_ entry: VoiceMemoReviewEntry, action: VoiceMemoReviewAction) {
        guard !resolvingReviewIds.contains(entry.id) else { return }
        resolvingReviewIds.insert(entry.id)
        Task {
            defer {
                Task { @MainActor in resolvingReviewIds.remove(entry.id) }
            }
            guard let router = await LiveToolRouter.shared.current() else {
                await MainActor.run { actionMessage = "MCP server not ready — try again shortly." }
                return
            }
            do {
                let result = try await VoiceMemoReviewResolver.resolve(
                    reviewId: entry.id,
                    action: action,
                    router: router
                )
                await MainActor.run {
                    actionMessage = result.warning ?? result.detail
                    reloadMemos()
                    NotificationCenter.default.post(name: .voiceMemoReviewDidChange, object: nil)
                }
            } catch {
                await MainActor.run {
                    actionMessage = "Resolve failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: dir)
    }

    // MARK: - Plan parsing (unchanged from MemoryProcessTab)

    private func parsePlan(from obj: [String: Value]) -> VoiceMemoPlan {
        let title = stringField(obj, "generatedTitle") ?? "Memo"
        let skip = boolField(obj, "skipMemoryKeep") ?? false
        let summary = stringField(obj, "summary") ?? ""
        var actions: [String] = []
        if case .array(let arr)? = obj["actions"] {
            actions = arr.compactMap { if case .string(let s) = $0 { return s }; return nil }
        }
        var intents: [VoiceMemoIntent] = []
        if case .array(let arr)? = obj["intents"] {
            for item in arr {
                guard case .object(let io) = item,
                      case .string(let kindRaw)? = io["kind"],
                      let kind = VoiceMemoIntentKind(rawValue: kindRaw) else { continue }
                let conf: Double = {
                    if case .double(let d)? = io["confidence"] { return d }
                    if case .int(let i)? = io["confidence"] { return Double(i) }
                    return 0.5
                }()
                var intent = VoiceMemoIntent(kind: kind, confidence: conf)
                if case .string(let s)? = io["entityKey"] { intent.entityKey = s }
                if case .string(let s)? = io["entityHint"] { intent.entityHint = s }
                if case .string(let s)? = io["title"] { intent.title = s }
                if case .object(let f)? = io["fields"] {
                    intent.fields = f.compactMapValues { if case .string(let s) = $0 { return s }; return nil }
                }
                intents.append(intent)
            }
        }
        let provenance = stringField(obj, "provenance").flatMap { ParseProvenance(rawValue: $0) } ?? .heuristic
        let degraded = boolField(obj, "degraded") ?? false
        return VoiceMemoPlan(
            generatedTitle: title, skipMemoryKeep: skip, summary: summary,
            actions: actions, intents: intents, provenance: provenance, degraded: degraded)
    }

    private func stringField(_ obj: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = obj[key] { return s }
        return nil
    }

    private func boolField(_ obj: [String: Value], _ key: String) -> Bool? {
        if case .bool(let b)? = obj[key] { return b }
        return nil
    }
}

// MARK: - Search field (extracted so its .accessibilityIdentifier sticks — see
// Loop 2 P1 fix note at the call site; mirrors MemoryRecallTab.RecallSearchField)

private struct MemosSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(BridgeTokens.fg4)
            TextField("Search memos", text: $query)
                .textFieldStyle(.plain)
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input))
    }
}

// MARK: - Registry configure sheet (pre-Confirm)
//
// Relocated verbatim from the now-deleted MemoryProcessTab.swift (2026-07-03
// integration cleanup) — this is the only piece of that file MemoryMemosTab
// still depends on (the pre-Confirm "pick a registry row" sheet). Fully
// self-contained: only touches the shared CockpitIntentRow/CockpitPickerState
// types (MemoryProcessCockpit.swift) plus BridgeAXID/BridgeTokens/BridgeButton/
// BridgeCardLabel — no dependency on MemoryProcessTab itself.

struct MemoryProcessRegistryConfigureSheet: View {
    let rows: [CockpitIntentRow]
    let allRows: [CockpitIntentRow]
    @Binding var selectedRowIdByIntentId: [String: String]
    @Binding var pickerByIntentId: [String: CockpitPickerState]
    var onLoadPicker: (CockpitIntentRow) async -> Void
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pick registry rows")
                .font(BridgeTokens.Typeface.name)
            Text("These registry intents need a row before Confirm can run.")
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg3)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(rows) { row in
                        registrySection(for: row)
                    }
                }
            }
            HStack {
                Spacer()
                BridgeButton("Cancel") { onCancel() }
                BridgeButton("Save", variant: .primary) { onSave() }
                    .disabled(!allPicked)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 320)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.registryConfigureSheet)
        .task {
            for row in rows {
                if pickerByIntentId[row.intentId] == nil {
                    await onLoadPicker(row)
                }
            }
        }
    }

    private var allPicked: Bool {
        rows.allSatisfy {
            !(selectedRowIdByIntentId[$0.intentId]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    @ViewBuilder
    private func registrySection(for row: CockpitIntentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BridgeCardLabel(row.destinationField)
            if let picker = pickerByIntentId[row.intentId] {
                if picker.stale {
                    Text("stale >24h").font(BridgeTokens.Typeface.meta).foregroundStyle(BridgeTokens.warn)
                }
                ForEach(picker.rows) { prow in
                    Button {
                        selectedRowIdByIntentId[row.intentId] = prow.id
                    } label: {
                        HStack {
                            Image(systemName: selectedRowIdByIntentId[row.intentId] == prow.id ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 10))
                            Text(prow.title).font(BridgeTokens.Typeface.meta)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.registryRow(entity: picker.entity, rowId: prow.id))
                }
            } else {
                ProgressView("Loading rows…")
            }
        }
    }
}
