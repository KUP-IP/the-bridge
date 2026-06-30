// MemoryProcessTab.swift — Process triage cockpit V1 (PKT-MEM-123)
// TheBridge · UI · Sections
//
// Three-pane layout: fixed memo sidebar · J3 center (title → transcript fade →
// intent tags → Confirm summary → Confirm) · collapsible activity push drawer.
// Batch commit orchestration delegates ordering/validation to MemoryProcessBatchConfirm.

import SwiftUI
import MCP

struct MemoryProcessTab: View {
    @State private var memos: [VoiceMemoRecording] = []
    @State private var selectedId: String?
    @State private var transcript: String = ""
    @State private var plan: VoiceMemoPlan?
    @State private var overrideIntentId: String?
    @State private var activity: [MemoryHubActivityEvent] = []
    @State private var statusMessage: String?
    @State private var isLoading = false
    @State private var loadingLabel = "Loading preview…"
    @State private var titleCache: [String: MemoTitle] = [:]
    @State private var titleDraft: String = ""
    @State private var cloudProvider: MemoryHubProvider?
    @State private var cloudBusy = false
    @State private var titleStatus: String?
    @State private var intentDiffBadges: [String: String] = [:]
    @State private var awaitingAgentMemoIds: Set<String> = []
    @State private var triageSessionActive = false

    // V1 — batch Confirm + per-intent registry maps
    @State private var checkedIntentIds: Set<String> = []
    @State private var transcriptExpanded = false
    @State private var selectedRowIdByIntentId: [String: String] = [:]
    @State private var pickerByIntentId: [String: CockpitPickerState] = [:]
    @State private var confirmPhase: ConfirmPhase = .idle
    @State private var batchOutcomes: [String: MemoryProcessBatchConfirm.BatchCommitOutcome] = [:]
    @State private var showRegistrySheet = false
    @State private var registrySheetRows: [CockpitIntentRow] = []
    @AppStorage("memory.process.activityDrawerOpen") private var activityDrawerOpen = false

    private enum ConfirmPhase { case idle, running, done }

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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            memoListZone
                .frame(width: 220)
            Divider().background(BridgeTokens.hairlineFaint)
            VStack(spacing: 0) {
                if triageSessionActive, selectedId != nil {
                    triageBanner
                    Divider().background(BridgeTokens.hairlineFaint)
                }
                HStack(alignment: .top, spacing: 0) {
                    centerPane
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                    activityDrawerColumn
                }
            }
        }
        .frame(minWidth: 960)
        .onAppear {
            reloadMemos()
            reloadActivity()
            Task { await restorePreviewSessionIfNeeded() }
            Task { await refreshTriageBanner() }
        }
        .onChange(of: selectedId) { _, _ in
            Task { await refreshTriageBanner() }
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
    }

    // MARK: - Triage banner

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

    // MARK: - Memo sidebar

    private var memoListZone: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Memos")
                if memos.isEmpty {
                    Text("No unprocessed voice memos.")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                } else {
                    ForEach(memos) { memo in memoRow(memo) }
                }
            }
            .padding(BridgeTokens.Space.paneH)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.memoList)
    }

    private func memoRow(_ memo: VoiceMemoRecording) -> some View {
        let selected = selectedId == memo.id
        let display = MemoryHubMemoTitler.listDisplay(recording: memo, cached: titleCache[memo.id])
        let titleColor: Color = display.isPlaceholder
            ? BridgeTokens.fg4
            : (selected ? BridgeTokens.fg1 : BridgeTokens.fg2)
        return Button {
            selectedId = memo.id
            overrideIntentId = nil
            confirmPhase = .idle
            batchOutcomes = [:]
            Task { await loadPreview(for: memo, forceRefresh: false) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(display.text)
                        .font(BridgeTokens.Typeface.name)
                        .foregroundStyle(titleColor)
                        .lineLimit(2)
                    if display.intentCount > 1 {
                        Text("+\(display.intentCount - 1)")
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.accent)
                    }
                }
                Text(MemoryHubCockpitLabels.transcriptSource(memo.transcriptSource, hasTranscript: memo.hasTranscript))
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
                HStack(spacing: 6) {
                    if awaitingAgentMemoIds.contains(memo.id) {
                        BridgeBadge(MemoryHubCockpitLabels.awaitingAgentLabel(), tone: .info)
                    }
                    if selectedId == memo.id, let plan {
                        BridgeBadge(
                            MemoryHubCockpitLabels.provenanceShort(plan.provenance, degraded: plan.degraded),
                            tone: plan.degraded ? .warn : .neutral
                        )
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? BridgeTokens.accent.opacity(0.12) : BridgeTokens.wellFill)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.memoRow(memo.id))
    }

    // MARK: - Center pane (J3)

    private var centerPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                centerHeader
                if let statusMessage {
                    Text(statusMessage)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                if isLoading {
                    ProgressView(loadingLabel)
                } else if let plan, selectedId != nil {
                    titleBlock
                    transcriptFadeBlock
                    intentTagsSection(plan: plan)
                    confirmSummaryStrip
                    confirmButtonBlock
                } else {
                    Text("Select a memo to preview and commit intents.")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                }
            }
            .padding(BridgeTokens.Space.paneH)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.centerPane)
    }

    private var centerHeader: some View {
        HStack {
            Spacer()
            if selectedId != nil, !isLoading {
                BridgeButton("Dry-run", systemImage: "play") {
                    Task { await runDryRun() }
                }
                .accessibilityIdentifier(BridgeAXID.Memory.Process.dryRun)
                BridgeButton("Re-run Understand", systemImage: "arrow.clockwise") {
                    guard let memoId = selectedId,
                          let memo = memos.first(where: { $0.id == memoId }) else { return }
                    MemoryHubTriageSessionBridge.invalidateForMemo(memoId: memoId)
                    confirmPhase = .idle
                    batchOutcomes = [:]
                    Task { await loadPreview(for: memo, forceRefresh: true) }
                }
                .accessibilityIdentifier(BridgeAXID.Memory.Process.refreshPreview)
            }
        }
    }

    private var titleBlock: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Title")
                if let display = currentTitleDisplay, !display.isEmpty {
                    Text(display)
                        .font(BridgeTokens.Typeface.name)
                        .foregroundStyle(BridgeTokens.fg1)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    TextField("Memo title", text: $titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(BridgeAXID.Memory.Process.titleRename)
                        .onChange(of: titleDraft) { _, _ in persistPreviewSession() }
                    BridgeButton("Rename", systemImage: "pencil", variant: .primary) { saveRename() }
                }
                if let provider = cloudProvider, MemoryHubProviderConfigStore.canRunCloud(provider) {
                    HStack(spacing: 8) {
                        BridgeButton("Improve title (cloud)", systemImage: "sparkles", isEnabled: !cloudBusy) {
                            Task { await improveTitleViaCloud(provider: provider) }
                        }
                        .accessibilityIdentifier(BridgeAXID.Memory.Process.titleCloud)
                        if cloudBusy { ProgressView().controlSize(.small) }
                    }
                }
                if let titleStatus {
                    Text(titleStatus)
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                }
            }
        }
    }

    private var transcriptFadeBlock: some View {
        MemoryProcessTranscriptFade(
            transcript: transcript,
            expanded: $transcriptExpanded,
            onToggle: { persistPreviewSession() }
        )
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
    }

    private var confirmSummaryStrip: some View {
        let lines = MemoryProcessBatchConfirm.confirmSummaryLines(checkedIds: checkedIntentIds, rows: rows)
        return Group {
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
                                    .lineLimit(3)
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

    // MARK: - Activity drawer

    @ViewBuilder
    private var activityDrawerColumn: some View {
        if activityDrawerOpen {
            Divider().background(BridgeTokens.hairlineFaint)
            activityDrawer
                .frame(width: 300)
        } else {
            activityDrawerCollapseStrip
                .frame(width: 40)
        }
    }

    private var activityDrawerCollapseStrip: some View {
        VStack {
            Button {
                activityDrawerOpen = true
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .foregroundStyle(BridgeTokens.fg3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(BridgeAXID.Memory.Process.activityDrawerToggle)
        }
        .background(BridgeTokens.wellFill.opacity(0.5))
        .accessibilityIdentifier(BridgeAXID.Memory.Process.activityDrawerCollapse)
    }

    private var activityDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BridgeCardLabel("Activity")
                Spacer()
                Button {
                    activityDrawerOpen = false
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(BridgeAXID.Memory.Process.activityDrawerToggle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider().background(BridgeTokens.hairlineFaint)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if activity.isEmpty {
                        Text("No recent receipts.")
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.fg4)
                    } else {
                        ForEach(activity) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(event.phase.rawValue) · \(event.status)")
                                    .font(BridgeTokens.Typeface.meta)
                                    .foregroundStyle(BridgeTokens.fg2)
                                Text(event.action)
                                    .font(BridgeTokens.Typeface.meta)
                                    .foregroundStyle(BridgeTokens.fg3)
                                    .lineLimit(2)
                                Text(event.receiptHashShort)
                                    .font(BridgeTokens.Typeface.mono)
                                    .foregroundStyle(BridgeTokens.fg4)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background { RoundedRectangle(cornerRadius: 6).fill(BridgeTokens.wellFill) }
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(BridgeTokens.wellFill.opacity(0.3))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.activityDrawer)
    }

    // MARK: - Data

    private func reloadMemos() {
        memos = VoiceMemoProcessor.listUnprocessed()
        titleCache = MemoryHubMemoTitleStore.load()
        awaitingAgentMemoIds = Set(
            VoiceMemoReviewStore.pendingEntries()
                .filter { $0.effectiveReviewTag == .awaitingAgent }
                .map(\.memoId)
        )
    }

    private func reloadActivity() {
        MemoryHubActivityLog.repairScan()
        activity = MemoryHubActivityLog.recent(limit: 50)
    }

    @MainActor
    private func loadPreview(for memo: VoiceMemoRecording, forceRefresh: Bool) async {
        await MemoryProcessPreviewSession.shared.setLastSelectedMemoId(memo.id)

        if !forceRefresh, let cached = await cachedBundle(for: memo) {
            applyBundle(cached)
            return
        }

        if forceRefresh {
            await MemoryProcessPreviewSession.shared.invalidate(memoId: memo.id)
        }

        isLoading = true
        statusMessage = MemoryHubCockpitLabels.selectStatus(hasTranscript: memo.hasTranscript)
        loadingLabel = statusMessage ?? "Loading preview…"
        defer { isLoading = false }
        guard let router = await JobsManager.shared.router_() else {
            statusMessage = "MCP server not ready."
            return
        }
        do {
            let result = try await router.dispatch(toolName: "voice_memo_get", arguments: .object([
                "memoId": .string(memo.id),
            ]))
            guard case .object(let envelope) = result,
                  case .object(let memoObj) = envelope["memo"],
                  case .string(let t) = memoObj["transcript"],
                  case .object(let planObj) = envelope["plan"] else {
                statusMessage = "Could not parse preview."
                return
            }
            transcript = t
            statusMessage = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? MemoryHubCockpitLabels.unresolvedTranscriptMessage()
                : nil
            let parsedPlan = parsePlan(from: planObj)
            plan = parsedPlan
            reloadPlanDiffBadges(memoId: memo.id)
            let title = MemoryHubMemoTitler.heuristicTitle(plan: parsedPlan, transcript: t)
            MemoryHubMemoTitleStore.put(title, memoId: memo.id)
            titleCache[memo.id] = MemoryHubMemoTitleStore.title(for: memo.id)
            titleStatus = nil
            titleDraft = MemoryHubMemoTitler.listDisplay(recording: memo, cached: titleCache[memo.id]).text
            cloudProvider = MemoryHubProviderConfigStore.load().first
            seedCheckedIntentsFromPlan()
            persistPreviewSession()
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
              let memoId = await MemoryProcessPreviewSession.shared.lastSelectedMemoId,
              let memo = memos.first(where: { $0.id == memoId }) else { return }
        selectedId = memoId
        await loadPreview(for: memo, forceRefresh: false)
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
        guard let router = await JobsManager.shared.router_() else {
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
        guard let router = await JobsManager.shared.router_() else {
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
        guard let router = await JobsManager.shared.router_() else {
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

    // MARK: - Plan parsing

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

// MARK: - Transcript fade

private struct MemoryProcessTranscriptFade: View {
    let transcript: String
    @Binding var expanded: Bool
    var onToggle: () -> Void

    private let collapsedLines = 4

    var body: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Transcript")
                if transcript.isEmpty {
                    Text(MemoryHubCockpitLabels.unresolvedTranscriptMessage())
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                } else if expanded {
                    ScrollView {
                        Text(transcript)
                            .font(BridgeTokens.Typeface.mono)
                            .foregroundStyle(BridgeTokens.fg2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                    Button("Show less") {
                        expanded = false
                        onToggle()
                    }
                    .font(BridgeTokens.Typeface.meta)
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.transcriptCollapse)
                } else {
                    ZStack(alignment: .bottom) {
                        Text(transcript)
                            .font(BridgeTokens.Typeface.mono)
                            .foregroundStyle(BridgeTokens.fg2)
                            .lineLimit(collapsedLines)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LinearGradient(
                            colors: [BridgeTokens.bgCanvas.opacity(0), BridgeTokens.bgCanvas],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 28)
                        .allowsHitTesting(false)
                    }
                    Button("Show more") {
                        expanded = true
                        onToggle()
                    }
                    .font(BridgeTokens.Typeface.meta)
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.transcriptExpand)
                }
            }
        }
    }
}

// MARK: - Registry configure sheet (pre-Confirm)

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
