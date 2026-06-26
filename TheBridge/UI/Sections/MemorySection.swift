// MemorySection.swift — Settings → Memory pane (PKT-MEM-102 + PKT-MEM-111).
//
// Tabs: Process · Inbox · Notion · Agent · Processing (model settings).

import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted when the voice-memo review queue mutates (dismiss, enqueue, …).
    static let voiceMemoReviewDidChange = Notification.Name("com.notionbridge.voiceMemoReviewDidChange")
}

/// Sidebar badge counter — shared so BridgeSectionNav can show pending count.
@MainActor
@Observable
public final class MemoryReviewBadgeCounter {
    public static let shared = MemoryReviewBadgeCounter()
    public private(set) var pendingCount: Int = 0

    public func refresh() {
        pendingCount = VoiceMemoReviewStore.load().pendingCount
    }

    private init() {
        refresh()
    }
}

public struct MemorySection: View {
    let anchor: String?

    @ObservedObject private var nav = SettingsNavigation.shared
    @State private var selection: Tab
    @State private var entries: [VoiceMemoReviewEntry] = []
    @State private var expandedIds: Set<String> = []
    @State private var actionMessage: String?
    @State private var resolvingIds: Set<String> = []
    @State private var inboxFilter: InboxFilter = .all

    public enum Tab: String, Hashable, CaseIterable, Sendable {
        case process, inbox, notion, agent, processing

        var label: String {
            switch self {
            case .process: return "Process"
            case .inbox: return "Inbox"
            case .notion: return "Notion"
            case .agent: return "Agent"
            case .processing: return "Processing"
            }
        }
    }

    /// Inbox status filter — matches notification deep-link intent (PKT-MEM-104 follow-up).
    public enum InboxFilter: String, CaseIterable, Sendable {
        case all, noTranscript, routingFailed, lowConfidence

        var label: String {
            switch self {
            case .all: return "All"
            case .noTranscript: return "No transcript"
            case .routingFailed: return "Routing failed"
            case .lowConfidence: return "Low confidence"
            }
        }
    }

    public init(anchor: String? = nil) {
        self.anchor = anchor
        self._selection = State(initialValue: MemorySection.tab(for: anchor) ?? .process)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, BridgeTokens.Space.cardGap)
            tabBar
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, 12)
                .padding(.bottom, 12)

            Divider().background(BridgeTokens.hairlineFaint)

            tabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .onAppear { reloadEntries() }
        .onChange(of: anchor) { _, newAnchor in
            if let t = MemorySection.tab(for: newAnchor) { selection = t }
        }
        .onChange(of: nav.anchor) { _, newAnchor in
            if let t = MemorySection.tab(for: newAnchor) { selection = t }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        BridgeGlassCard(cornerRadius: BridgeTokens.Radius.card, padding: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(NotionPalette.purple.opacity(0.20))
                        .frame(width: 44, height: 44)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(NotionPalette.purple.opacity(0.85))
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory")
                        .font(BridgeTokens.Typeface.hero)
                        .foregroundStyle(BridgeTokens.fg1)
                        .accessibilityAddTraits(.isHeader)
                    Text("Voice capture triage, Notion Memory rows, and agent recall.")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                if selection == .inbox, !entries.isEmpty {
                    BridgeBadge("\(entries.count) pending", tone: .warn, showsDot: true)
                }
            }
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory section tabs")
        .accessibilityIdentifier(BridgeAXID.Memory.tabBar)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let on = selection == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { selection = tab }
        } label: {
            Text(tab.label)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? BridgeTokens.fg1 : BridgeTokens.fg3)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(minHeight: 28)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(BridgeTokens.accent.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 0.5))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier(BridgeAXID.Memory.tab(tab.rawValue))
    }

    @ViewBuilder
    private var tabBody: some View {
        switch selection {
        case .process: MemoryProcessTab()
        case .inbox: inboxTab
        case .notion: MemoryNotionTab()
        case .agent: MemoryAgentTab()
        case .processing: MemoryProcessingTab()
        }
    }

    // MARK: - Inbox

    private var filteredEntries: [VoiceMemoReviewEntry] {
        entries.filter { entry in
            switch inboxFilter {
            case .all: return true
            case .noTranscript: return statusLabel(for: entry) == "No transcript"
            case .routingFailed: return statusLabel(for: entry) == "Routing failed"
            case .lowConfidence: return statusLabel(for: entry) == "Low confidence"
            }
        }
    }

    private var inboxTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BridgeTokens.Space.cardGap) {
                inboxFilterBar
                if let actionMessage {
                    Text(actionMessage)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                if filteredEntries.isEmpty {
                    emptyInbox
                } else {
                    ForEach(filteredEntries) { entry in
                        inboxRow(entry)
                    }
                }
            }
            .padding(.horizontal, BridgeTokens.Space.paneH)
            .padding(.vertical, BridgeTokens.Space.cardGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(BridgeAXID.Memory.inboxList)
    }

    private var inboxFilterBar: some View {
        HStack(spacing: 6) {
            ForEach(InboxFilter.allCases, id: \.self) { filter in
                let on = inboxFilter == filter
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) { inboxFilter = filter }
                } label: {
                    Text(filter.label)
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? BridgeTokens.fg1 : BridgeTokens.fg3)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background {
                            if on {
                                Capsule().fill(BridgeTokens.accent.opacity(0.16))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(BridgeAXID.Memory.inboxFilterBar + ".\(filter.rawValue)")
            }
        }
        .accessibilityIdentifier(BridgeAXID.Memory.inboxFilterBar)
    }

    private var emptyInbox: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Inbox empty")
                Text("Voice memos that need triage appear here — routing failures, low confidence, or missing transcripts.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inboxRow(_ entry: VoiceMemoReviewEntry) -> some View {
        let expanded = expandedIds.contains(entry.id)
        return BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // PKT-MEM-114 P2 — read-only consumer of the title cache: prefer the
                    // intent-led title when one exists, else the stored memoTitle. Never generates.
                    Text(MemoryHubMemoTitleStore.title(for: entry.memoId)?.title ?? entry.memoTitle)
                        .font(BridgeTokens.Typeface.name)
                        .foregroundStyle(BridgeTokens.fg1)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    BridgeBadge(transcriptSourceLabel(for: entry), tone: transcriptSourceTone(for: entry))
                    BridgeBadge(statusLabel(for: entry), tone: statusTone(for: entry), showsDot: true)
                }
                HStack(spacing: 12) {
                    if let date = formattedQueuedDate(entry.queuedAt) {
                        Text(date)
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                    Text("\(entry.intentKind) · \(Int(entry.confidence * 100))%")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                }
                Text(entry.reason)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)

                if expanded, !entry.transcriptExcerpt.isEmpty {
                    Text(entry.transcriptExcerpt)
                        .font(BridgeTokens.Typeface.mono)
                        .foregroundStyle(BridgeTokens.fg2)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
                }

                HStack(spacing: 8) {
                    if !entry.transcriptExcerpt.isEmpty {
                        BridgeButton(expanded ? "Hide transcript" : "Show transcript", variant: .link) {
                            toggleExpanded(entry.id)
                        }
                    }
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
        }
        .accessibilityIdentifier(BridgeAXID.Memory.inboxRow)
    }

    // MARK: - Actions

    private func reloadEntries() {
        entries = VoiceMemoReviewStore.pendingEntries()
        MemoryReviewBadgeCounter.shared.refresh()
    }

    private func dismissEntry(_ entry: VoiceMemoReviewEntry) {
        do {
            guard try VoiceMemoReviewStore.dismiss(id: entry.id) else {
                actionMessage = "Entry not found."
                return
            }
            actionMessage = nil
            reloadEntries()
            NotificationCenter.default.post(name: .voiceMemoReviewDidChange, object: nil)
        } catch {
            actionMessage = "Dismiss failed: \(error.localizedDescription)"
        }
    }

    private func resolveEntry(_ entry: VoiceMemoReviewEntry, action: VoiceMemoReviewAction) {
        guard !resolvingIds.contains(entry.id) else { return }
        resolvingIds.insert(entry.id)
        Task {
            defer {
                Task { @MainActor in resolvingIds.remove(entry.id) }
            }
            guard let router = await JobsManager.shared.router_() else {
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
                    if let warning = result.warning {
                        actionMessage = warning
                    } else {
                        actionMessage = result.detail
                    }
                    reloadEntries()
                    NotificationCenter.default.post(name: .voiceMemoReviewDidChange, object: nil)
                }
            } catch {
                await MainActor.run {
                    actionMessage = "Resolve failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func toggleExpanded(_ id: String) {
        if expandedIds.contains(id) {
            expandedIds.remove(id)
        } else {
            expandedIds.insert(id)
        }
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().path
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: dir)
    }

    // MARK: - Labels

    private func transcriptSourceLabel(for entry: VoiceMemoReviewEntry) -> String {
        guard let path = entry.memoPath else { return "Missing" }
        let audio = URL(fileURLWithPath: path)
        switch VoiceMemoDiscovery.detectTranscriptSource(for: audio) {
        case .apple: return "Apple"
        case .parakeet: return "Parakeet"
        case .sidecar: return "Sidecar"
        case .none:
            return entry.transcriptExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Missing" : "Sidecar"
        }
    }

    private func transcriptSourceTone(for entry: VoiceMemoReviewEntry) -> BridgeBadge.Tone {
        transcriptSourceLabel(for: entry) == "Missing" ? .warn : .info
    }

    private func statusLabel(for entry: VoiceMemoReviewEntry) -> String {
        let reason = entry.reason.lowercased()
        if reason.contains("no transcript") || reason.contains("missing transcript") {
            return "No transcript"
        }
        if reason.contains("routing") || reason.contains("classify") {
            return "Routing failed"
        }
        if entry.confidence < 0.65 {
            return "Low confidence"
        }
        return "Transcribed"
    }

    private func statusTone(for entry: VoiceMemoReviewEntry) -> BridgeBadge.Tone {
        switch statusLabel(for: entry) {
        case "No transcript": return .bad
        case "Routing failed": return .warn
        case "Low confidence": return .warn
        default: return .ok
        }
    }

    private func formattedQueuedDate(_ iso: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    // MARK: - Deep-link anchor → tab

    public static func tab(for anchor: String?) -> Tab? {
        guard let raw = anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: ""),
            !raw.isEmpty else { return nil }
        switch raw {
        case "process", "curator", "pipeline":
            return .process
        case "inbox", "review", "voicememos", "voicememo", "voice":
            return .inbox
        case "notion", "registry":
            return .notion
        case "agent", "sqlite", "remember":
            return .agent
        case "processing", "models", "routing":
            return .processing
        default:
            return nil
        }
    }
}
