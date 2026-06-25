// MemoryProcessTab.swift — Process tab: preview + pipeline drawer (PKT-MEM-111 U1)
// TheBridge · UI · Sections

import SwiftUI
import MCP

struct MemoryProcessTab: View {
    @State private var memos: [VoiceMemoRecording] = []
    @State private var selectedId: String?
    @State private var previewPlan: VoiceMemoPlan?
    @State private var previewTranscript: String = ""
    @State private var statusMessage: String?
    @State private var isLoading = false
    @State private var pipelineStep: PipelineStep = .transcribe

    enum PipelineStep: String, CaseIterable, Sendable {
        case transcribe, understand, plan, execute

        var label: String {
            switch self {
            case .transcribe: return "Transcribe"
            case .understand: return "Understand"
            case .plan: return "Plan"
            case .execute: return "Execute"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            memoList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
            Divider().background(BridgeTokens.hairlineFaint)
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { reloadMemos() }
    }

    private var memoList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Unprocessed")
                if memos.isEmpty {
                    Text("No unprocessed voice memos.")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                } else {
                    ForEach(memos) { memo in
                        memoRow(memo)
                    }
                }
            }
            .padding(BridgeTokens.Space.paneH)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.processList)
    }

    private func memoRow(_ memo: VoiceMemoRecording) -> some View {
        let selected = selectedId == memo.id
        return Button {
            selectedId = memo.id
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
    }

    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                pipelineBar
                if let statusMessage {
                    Text(statusMessage)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                if isLoading {
                    ProgressView("Loading preview…")
                } else if let plan = previewPlan {
                    planPreview(plan)
                } else {
                    Text("Select a memo to preview routing.")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg4)
                }
            }
            .padding(BridgeTokens.Space.paneH)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.processPreview)
    }

    private var pipelineBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(PipelineStep.allCases.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg4)
                        .padding(.horizontal, 6)
                }
                Text(step.label)
                    .font(.system(size: 11.5, weight: pipelineStep == step ? .semibold : .regular))
                    .foregroundStyle(pipelineStep == step ? BridgeTokens.fg1 : BridgeTokens.fg4)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background {
                        if pipelineStep == step {
                            Capsule().fill(BridgeTokens.accent.opacity(0.16))
                        }
                    }
            }
            Spacer()
            Text(VoiceMemoCuratorRouter.effectiveMode().label)
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.processPipeline)
    }

    private func planPreview(_ plan: VoiceMemoPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BridgeGlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    BridgeCardLabel("Transcript")
                    Text(previewTranscript.prefix(1200).description)
                        .font(BridgeTokens.Typeface.mono)
                        .foregroundStyle(BridgeTokens.fg2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            BridgeGlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    BridgeCardLabel("Plan — \(plan.generatedTitle)")
                    Text(plan.summary)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg2)
                    ForEach(Array(plan.intents.enumerated()), id: \.offset) { _, intent in
                        HStack(spacing: 8) {
                            BridgeBadge(intent.kind.rawValue, tone: intent.confidence >= 0.85 ? .ok : .warn)
                            Text("\(Int(intent.confidence * 100))%")
                                .font(BridgeTokens.Typeface.meta)
                                .foregroundStyle(BridgeTokens.fg4)
                            if let hint = intent.entityHint {
                                Text(hint)
                                    .font(BridgeTokens.Typeface.meta)
                                    .foregroundStyle(BridgeTokens.fg3)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                BridgeButton("Dry-run process", systemImage: "play") {
                    Task { await runProcess(dryRun: true) }
                }
                .accessibilityIdentifier(BridgeAXID.Memory.processDryRun)
                BridgeButton("Process now", systemImage: "bolt", variant: .primary) {
                    Task { await runProcess(dryRun: false) }
                }
                .accessibilityIdentifier(BridgeAXID.Memory.processExecute)
            }
        }
    }

    private func reloadMemos() {
        memos = VoiceMemoProcessor.listUnprocessed()
    }

    @MainActor
    private func loadPreview(for memo: VoiceMemoRecording) async {
        isLoading = true
        statusMessage = nil
        pipelineStep = .transcribe
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
                  case .string(let transcript) = memoObj["transcript"],
                  case .object(let planObj) = envelope["plan"] else {
                statusMessage = "Could not parse preview."
                return
            }
            previewTranscript = transcript
            pipelineStep = .understand
            previewPlan = parsePlan(from: planObj)
            pipelineStep = .plan
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runProcess(dryRun: Bool) async {
        guard let memoId = selectedId else { return }
        guard let router = await JobsManager.shared.router_() else {
            statusMessage = "MCP server not ready."
            return
        }
        pipelineStep = .execute
        do {
            let result = try await router.dispatch(toolName: "voice_memo_process", arguments: .object([
                "memoId": .string(memoId),
                "mode": .string("single"),
                "dryRun": .bool(dryRun),
            ]))
            if case .object(let env) = result, case .string(let summary)? = env["summary"] {
                statusMessage = summary
            }
            reloadMemos()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

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
