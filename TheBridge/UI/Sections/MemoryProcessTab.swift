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

    private var rows: [CockpitIntentRow] {
        guard let plan, let selectedId else { return [] }
        return MemoryProcessCockpit.intentRows(memoId: selectedId, plan: plan, overrideIntentId: overrideIntentId)
    }

    private var inspectorRow: CockpitIntentRow? {
        rows.first { $0.intentId == selectedIntentId } ?? rows.first { $0.isPrimary } ?? rows.first
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
        return Button {
            selectedId = memo.id
            overrideIntentId = nil
            selectedIntentId = nil
            picker = nil
            selectedRowId = nil
            Task { await loadPreview(for: memo) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(memo.title)
                    .font(BridgeTokens.Typeface.name)
                    .foregroundStyle(selected ? BridgeTokens.fg1 : BridgeTokens.fg2)
                    .lineLimit(2)
                Text(memo.hasTranscript ? memo.transcriptSource.rawValue : "no transcript")
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
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
                    ProgressView("Loading preview…")
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
                    BridgeBadge(row.kind.rawValue, tone: row.status == "review" ? .warn : (row.confidence >= 0.85 ? .ok : .warn))
                    Text("\(Int(row.confidence * 100))%")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                    Spacer()
                    Text(row.status)
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(row.isPrimary ? BridgeTokens.accent : BridgeTokens.fg4)
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
                Text(transcript.prefix(900).description)
                    .font(BridgeTokens.Typeface.mono)
                    .foregroundStyle(BridgeTokens.fg2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func inspectorDetail(plan: VoiceMemoPlan, row: CockpitIntentRow) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Commit — \(row.kind.rawValue)")
                Text(row.destinationField)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg2)

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
        statusMessage = nil
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
            plan = parsePlan(from: planObj)
        } catch {
            statusMessage = error.localizedDescription
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
            if ok { statusMessage = "Committed \(row.kind.rawValue): \(detail)" }
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
        return VoiceMemoPlan(generatedTitle: title, skipMemoryKeep: skip, summary: summary, actions: actions, intents: intents)
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
