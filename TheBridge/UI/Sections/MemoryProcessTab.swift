// MemoryProcessTab.swift — Process triage cockpit (PKT-MEM-106 0b)
// TheBridge · UI · Sections
//
// Three zones + activity strip: memo list · intent table · detail/commit inspector.
// Logic lives in the tested, UI-free `MemoryProcessCockpit` core; this view renders
// it and threads per-intent commit (+ picker rowId) through `voice_memo_commit`.

import SwiftUI
import MCP

struct MemoryProcessTab: View {
    @State private var memos: [VoiceMemoRecording] = []
    @State private var selectedId: String?
    @State private var transcript: String = ""
    @State private var plan: VoiceMemoPlan?
    @State private var overrideIntentId: String?
    @State private var selectedIntentId: String?
    @State private var picker: CockpitPickerState?
    @State private var selectedRowId: String?
    @State private var activity: [MemoryHubActivityEvent] = []
    @State private var statusMessage: String?
    @State private var isLoading = false
    /// W3 — the spinner label while a preview loads. Distinct for a no-transcript memo
    /// ("Transcribing on-device…") so an on-device transcription run reads as work, not a hang.
    @State private var loadingLabel = "Loading preview…"
    /// PKT-MEM-114 P2 — cached intent-led titles (memo-titles.json), read-only over the
    /// parsed plan/election. Loaded with the memo list; refreshed on selection.
    @State private var titleCache: [String: MemoTitle] = [:]
    /// PKT-MEM-114 P3b — operator rename field (detail inspector). Seeded with the current
    /// display title on selection; on Save it writes a pinned `.edited` title.
    @State private var titleDraft: String = ""
    /// PKT-MEM-114 P3b — Tier-3 cloud title state: the loaded provider (gates the button),
    /// an in-flight flag, and a small inline status line. Cloud is MANUAL-only.
    @State private var cloudProvider: MemoryHubProvider?
    @State private var cloudBusy = false
    @State private var titleStatus: String?
    @State private var intentDiffBadges: [String: String] = [:]
    @State private var awaitingAgentMemoIds: Set<String> = []

    private var rows: [CockpitIntentRow] {
        guard let plan, let selectedId else { return [] }
        return MemoryProcessCockpit.intentRows(memoId: selectedId, plan: plan, overrideIntentId: overrideIntentId)
    }

    private var inspectorRow: CockpitIntentRow? {
        rows.first { $0.intentId == selectedIntentId } ?? rows.first { $0.isPrimary } ?? rows.first
    }

    /// The resolved, full display title for the read-only wrapping Text (W3). Prefers the
    /// cached title (carries the edited/local/cloud upgrade), else the parsed plan title.
    private var currentTitleDisplay: String? {
        if let memoId = selectedId, let cached = titleCache[memoId]?.title, !cached.isEmpty {
            return cached
        }
        return plan?.generatedTitle
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                memoListZone
                    .frame(minWidth: 210, idealWidth: 230, maxWidth: 250)
                Divider().background(BridgeTokens.hairlineFaint)
                intentTableZone
                    .frame(maxWidth: .infinity)
                Divider().background(BridgeTokens.hairlineFaint)
                detailInspectorZone
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider().background(BridgeTokens.hairlineFaint)
            activityStripZone
                .frame(height: 96)
        }
        .onAppear { reloadMemos(); reloadActivity() }
    }

    // MARK: Zone 1 — memo list

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
        // Muted (fg4) when it's the computed date floor — signals "no real title yet".
        let titleColor: Color = display.isPlaceholder
            ? BridgeTokens.fg4
            : (selected ? BridgeTokens.fg1 : BridgeTokens.fg2)
        return Button {
            selectedId = memo.id
            overrideIntentId = nil
            selectedIntentId = nil
            picker = nil
            selectedRowId = nil
            Task { await loadPreview(for: memo) }
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

    // MARK: Zone 2 — intent table

    private var intentTableZone: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Intents")
                if isLoading {
                    ProgressView(loadingLabel)
                } else if rows.isEmpty {
                    Text(selectedId == nil ? "Select a memo." : "No intents detected.")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                } else {
                    ForEach(rows) { row in intentRowView(row) }
                }
            }
            .padding(BridgeTokens.Space.paneH)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.intentTable)
    }

    private func intentRowView(_ row: CockpitIntentRow) -> some View {
        let open = inspectorRow?.intentId == row.intentId
        return Button {
            selectedIntentId = row.intentId
            picker = nil
            selectedRowId = nil
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: row.isPrimary ? "star.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(row.isPrimary ? BridgeTokens.accent : BridgeTokens.fg4)
                    BridgeBadge(MemoryHubCockpitLabels.intentKind(row.kind), tone: row.status == "review" ? .warn : (row.confidence >= 0.85 ? .ok : .warn))
                    Text("\(Int(row.confidence * 100))%")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                    Spacer()
                    Text(MemoryHubCockpitLabels.intentStatus(row.status))
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(row.isPrimary ? BridgeTokens.accent : BridgeTokens.fg4)
                    if let diff = intentDiffBadges[row.intentId] {
                        BridgeBadge(MemoryHubCockpitLabels.diffBadgeLabel(diff), tone: .info)
                    }
                }
                Text(row.destinationField)
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg3)
                    .lineLimit(1)
                if let warning = row.warning {
                    Text(warning)
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.warn)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(open ? BridgeTokens.accent.opacity(0.10) : BridgeTokens.wellFill)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.intentRow(row.intentId))
    }

    // MARK: Zone 3 — detail / commit inspector

    private var detailInspectorZone: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                if let plan, let row = inspectorRow {
                    transcriptCard
                    titleEditorCard
                    inspectorDetail(plan: plan, row: row)
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
        .accessibilityIdentifier(BridgeAXID.Memory.Process.detailInspector)
    }

    private var transcriptCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Transcript")
                // W3 — FULL transcript (the prior `prefix(900)` truncated long memos so the
                // operator couldn't read them). Its own ScrollView with a bounded maxHeight
                // keeps the title/commit cards reachable while the entire text is scrollable.
                if transcript.isEmpty {
                    Text(MemoryHubCockpitLabels.unresolvedTranscriptMessage())
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        Text(transcript)
                            .font(BridgeTokens.Typeface.mono)
                            .foregroundStyle(BridgeTokens.fg2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
    }

    /// PKT-MEM-114 P3b — title editor: operator rename (→ pinned `.edited`) + manual Tier-3
    /// cloud polish. Read-only over the plan/election; only the separate title cache is touched.
    private var titleEditorCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Title")
                // W3 — read-only WRAPPING display of the FULL generated title (the single-line
                // rename field below clipped long titles, so the operator couldn't read them).
                // Wraps up to 3 lines; the rename TextField beneath stays the edit affordance.
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
                    BridgeButton("Rename", systemImage: "pencil", variant: .primary) { saveRename() }
                        .accessibilityIdentifier(BridgeAXID.Memory.Process.titleRename)
                }
                // Tier-3 cloud is MANUAL-only and shown/enabled solely when the loaded provider
                // is enabled with a model + a configured key (canRunCloud). Otherwise hidden.
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

    @ViewBuilder
    private func inspectorDetail(plan: VoiceMemoPlan, row: CockpitIntentRow) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Commit — \(MemoryHubCockpitLabels.intentKind(row.kind))")
                Text(row.destinationField)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg2)

                // W3 — provenance badge: WHO produced these intents (frontier agent / cloud /
                // local), and whether the result is a degraded fallback. Passive (no AX id).
                BridgeBadge(
                    MemoryHubCockpitLabels.provenanceBadge(plan.provenance, degraded: plan.degraded),
                    tone: plan.degraded ? .warn : .neutral
                )

                // W3/W4 — commit-value preview: the text that will be written, read-only, so the
                // operator commits with sight not blind. The label is honest about partial cases
                // (first-of-N fields / append-merge) via `commitWriteLabel`.
                if let value = MemoryProcessCockpit.commitValuePreview(for: row) {
                    VStack(alignment: .leading, spacing: 4) {
                        BridgeCardLabel(MemoryProcessCockpit.commitWriteLabel(for: row) ?? "Will write")
                        Text(value)
                            .font(BridgeTokens.Typeface.mono)
                            .foregroundStyle(BridgeTokens.fg2)
                            .textSelection(.enabled)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background { RoundedRectangle(cornerRadius: 6).fill(BridgeTokens.wellFill) }
                    }
                }

                if !row.isPrimary {
                    BridgeButton("Make primary", systemImage: "star") {
                        overrideIntentId = row.intentId
                    }
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.primaryOverride(row.intentId))
                }

                // Inline picker only when disambiguation is needed: multiple registry lanes
                // OR an ambiguous/empty row hint (MEMORY-HUB-UI-VISION contract). A lone
                // registry lane with a good hint commits by hint without a picker.
                if row.kind == .registryUpdate, MemoryProcessCockpit.needsPicker(rows: rows) {
                    registryPicker(for: row)
                }

                HStack(spacing: 8) {
                    BridgeButton("Dry-run", systemImage: "play") {
                        Task { await runDryRun() }
                    }
                    BridgeButton("Commit", systemImage: "checkmark.seal", variant: .primary) {
                        Task { await commit(row) }
                    }
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.commit(row.intentId))
                }
            }
        }
    }

    @ViewBuilder
    private func registryPicker(for row: CockpitIntentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                BridgeCardLabel("Registry row")
                Spacer()
                if let picker, picker.stale {
                    Text("stale >24h").font(BridgeTokens.Typeface.meta).foregroundStyle(BridgeTokens.warn)
                }
                Button("Load") { Task { await loadPicker(for: row) } }
                    .font(BridgeTokens.Typeface.meta)
            }
            if let picker {
                ForEach(picker.rows) { prow in
                    Button {
                        selectedRowId = prow.id
                    } label: {
                        HStack {
                            Image(systemName: selectedRowId == prow.id ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 10))
                            Text(prow.title).font(BridgeTokens.Typeface.meta)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(BridgeAXID.Memory.Process.registryRow(entity: picker.entity, rowId: prow.id))
                }
                if let err = picker.sourceError {
                    Text(err).font(BridgeTokens.Typeface.meta).foregroundStyle(BridgeTokens.fg4)
                }
            }
        }
    }

    // MARK: Activity strip

    private var activityStripZone: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                BridgeCardLabel("Activity")
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
                            Text(event.action).font(BridgeTokens.Typeface.meta).foregroundStyle(BridgeTokens.fg3).lineLimit(1)
                            Text(event.receiptHashShort).font(BridgeTokens.Typeface.mono).foregroundStyle(BridgeTokens.fg4)
                        }
                        .padding(8)
                        .background { RoundedRectangle(cornerRadius: 6).fill(BridgeTokens.wellFill) }
                    }
                }
            }
            .padding(.horizontal, BridgeTokens.Space.paneH)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(BridgeAXID.Memory.Process.activityStrip)
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
        // Non-destructive corruption recovery: record a repair receipt if the JSONL has
        // corrupt lines (idempotent) so retention can resume + the operator is surfaced it.
        MemoryHubActivityLog.repairScan()
        activity = MemoryHubActivityLog.recent(limit: 8)
    }

    @MainActor
    private func loadPreview(for memo: VoiceMemoRecording) async {
        isLoading = true
        // W3 — DISTINCT pre-await status: a no-transcript memo triggers an on-device
        // transcription run (first run may DOWNLOAD the model) here, which otherwise reads
        // as a hang. The "transcribing" line makes the run legible. Shown in both the intent
        // zone (isLoading spinner label) and the inspector status line.
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
            // W3 — clear the transcribing line once resolved; if STILL empty (on-device
            // transcription disabled + no Apple transcript), surface the actionable next step
            // instead of leaving the inspector silent.
            statusMessage = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? MemoryHubCockpitLabels.unresolvedTranscriptMessage()
                : nil
            let parsedPlan = parsePlan(from: planObj)
            plan = parsedPlan
            reloadPlanDiffBadges(memoId: memo.id)
            // PKT-MEM-114 P2 — generate-on-select: cache the Tier-1 heuristic title.
            // edited-pinned put() preserves a prior human rename; read-only over the plan.
            let title = MemoryHubMemoTitler.heuristicTitle(plan: parsedPlan, transcript: t)
            MemoryHubMemoTitleStore.put(title, memoId: memo.id)
            titleCache[memo.id] = MemoryHubMemoTitleStore.title(for: memo.id)
            // PKT-MEM-114 P3b — seed the rename field with the resolved display title and load
            // the cloud provider (gates the Tier-3 button). Read-only over the plan/election.
            titleStatus = nil
            titleDraft = MemoryHubMemoTitler.listDisplay(recording: memo, cached: titleCache[memo.id]).text
            cloudProvider = MemoryHubProviderConfigStore.load().first
            // PKT-MEM-114 P3a — Tier-2 local upgrade: AUTO only when Ollama processing is
            // enabled. Non-blocking; on a better title it caches `.local` (edited-pinned) and
            // refreshes the row on the main actor. Failure/timeout keeps the heuristic silently.
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

    private func reloadPlanDiffBadges(memoId: String) {
        let snaps = MemoryHubPlanSnapshotStore.load(memoId: memoId)
        guard let heuristic = snaps.last(where: { $0.provenance == .heuristic }),
              let enhanced = snaps.filter({ $0.isEnhanced }).max(by: { $0.version < $1.version }) else {
            intentDiffBadges = [:]
            return
        }
        intentDiffBadges = MemoryHubPlanSnapshotStore.diffBadges(from: heuristic, to: enhanced)
    }

    // MARK: PKT-MEM-114 P3b — title rename + manual cloud title

    /// Operator rename → pinned `.edited` title. Empty/whitespace is a no-op. Carries the
    /// current cached intentCount + transcriptHash so the `+N` badge and freshness survive the
    /// edit. The store's edited-pin then guarantees later auto tiers never overwrite it.
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
    }

    /// Tier-3 cloud title (MANUAL only). POSTs an OpenAI-compatible chat-completions request via
    /// the testable `MemoryHubCloudTitler` helper, caching a pinned-safe `.cloud` title on
    /// success. Any failure/timeout surfaces a small inline status and keeps the existing title —
    /// it NEVER blocks the UI and queues NO review. The key is read inside the helper, never here.
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
            // Keep the existing title; surface a brief, non-blocking status (no key in the message).
            titleStatus = "Cloud title unavailable — kept the current title."
        }
    }

    @MainActor
    private func loadPicker(for row: CockpitIntentRow) async {
        guard let entity = row.entityKey else { return }
        guard let router = await JobsManager.shared.router_() else {
            picker = MemoryProcessCockpit.picker(entity: entity, liveRows: nil, sourceError: "MCP server not ready")
            return
        }
        do {
            let result = try await router.dispatch(toolName: "registry_list", arguments: .object([
                "entity": .string(entity), "limit": .int(100),
            ]))
            guard case .object(let env) = result, case .array(let rawRows)? = env["rows"] else {
                picker = MemoryProcessCockpit.picker(entity: entity, liveRows: nil, sourceError: "registry_list empty")
                return
            }
            let liveRows: [MemoryHubRegistryRow] = rawRows.compactMap { r in
                guard case .object(let o) = r, case .string(let id)? = o["id"], case .string(let title)? = o["title"] else { return nil }
                return MemoryHubRegistryRow(id: id, title: title)
            }
            picker = MemoryProcessCockpit.picker(entity: entity, liveRows: liveRows)
        } catch {
            picker = MemoryProcessCockpit.picker(entity: entity, liveRows: nil, sourceError: error.localizedDescription)
        }
    }

    @MainActor
    private func runDryRun() async {
        guard let memoId = selectedId else { return }
        guard let router = await JobsManager.shared.router_() else { statusMessage = "MCP server not ready."; return }
        do {
            let result = try await router.dispatch(toolName: "voice_memo_process", arguments: .object([
                "memoId": .string(memoId), "mode": .string("single"), "dryRun": .bool(true),
            ]))
            if case .object(let env) = result, case .string(let summary)? = env["summary"] { statusMessage = summary }
        } catch { statusMessage = error.localizedDescription }
    }

    @MainActor
    private func commit(_ row: CockpitIntentRow) async {
        guard let memoId = selectedId else { return }
        guard let router = await JobsManager.shared.router_() else { statusMessage = "MCP server not ready."; return }
        let args = MemoryProcessCockpit.commitArguments(memoId: memoId, row: row, selectedRowId: selectedRowId)
        var ok = false
        var detail = ""
        do {
            let result = try await router.dispatch(toolName: "voice_memo_commit", arguments: .object(args))
            if case .object(let env) = result {
                if case .bool(let b)? = env["ok"] { ok = b }
                if case .string(let d)? = env["detail"] { detail = d }
                if case .bool(true)? = env["needsManual"] { statusMessage = "Manual commit needed: \(detail)"; ok = false }
            }
            if ok { statusMessage = "Committed \(MemoryHubCockpitLabels.intentKind(row.kind)): \(detail)" }
        } catch {
            detail = error.localizedDescription
            statusMessage = detail
        }
        let event = MemoryHubActivityEvent(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            memoId: memoId, intentId: row.intentId, phase: .execute,
            action: "voice_memo_commit:\(row.kind.rawValue)",
            status: ok ? "executed" : "failed",
            provenance: overrideIntentId != nil ? "override" : "election",
            actor: "operator", detail: String(detail.prefix(160))
        )
        try? MemoryHubActivityLog.append(event)
        reloadActivity()
        reloadMemos()
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
        // FRONTIER-FIRST W3 — decode the provenance/degraded the envelope now carries
        // (planValue, W1 fields). Default to the heuristic floor when absent so an older
        // envelope still parses; the inspector badge reads these.
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
