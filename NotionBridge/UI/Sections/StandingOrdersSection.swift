// StandingOrdersSection.swift — Settings → Standing Orders pane.
// PKT-9 UI v3.5.

import SwiftUI

public struct StandingOrdersSection: View {
    @State private var snapshot: StandingOrdersStore.Snapshot? = nil
    @State private var draft: String = ""
    @State private var loadError: String? = nil
    @State private var saveMessage: String? = nil
    @State private var saveIsError: Bool = false
    @State private var selectedTemplate: StandingOrdersStore.Template? = nil
    /// v3.7·1: Routing skills loaded from the on-disk cache (populated by
    /// `SkillsCacheWriter`). Empty until `.task` finishes; the composer
    /// renders "None registered yet" until the cache is read. Refreshed
    /// when the Notion-bound `routingSkillsForDiscovery` set changes.
    @State private var cachedRouting: [RoutingSkillSummary] = []

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                if let err = loadError {
                    errorBanner(err)
                }
                editorCard
                composedPreviewCard
                templatesCard
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task {
            await load()
            await refreshCachedRouting()
        }
    }

    // MARK: - Cards

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(NotionPalette.purple.opacity(0.20))
                        .frame(width: 44, height: 44)
                    Image(systemName: "scroll")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 0.78, green: 0.71, blue: 1.0))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Standing Orders")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Loaded by every MCP client at session start. Edit once, applied everywhere.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let s = snapshot {
                    VStack(spacing: 1) {
                        Text("\(s.estimatedTokens)")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color(red: 0.78, green: 0.71, blue: 1.0))
                        Text("tokens").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var editorCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    BridgeCardLabel("Markdown body")
                    Spacer()
                    if let snapshot {
                        Text("hash · \(String(snapshot.hash.prefix(8)))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                HStack(spacing: 8) {
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(snapshot == nil || draft == snapshot?.markdown)
                    Button("Revert") {
                        draft = snapshot?.markdown ?? ""
                        saveMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(snapshot == nil || draft == snapshot?.markdown)
                    Spacer()
                    if let msg = saveMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(saveIsError ? .red : .green)
                    }
                }
            }
        }
    }

    private var composedPreviewCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    BridgeCardLabel("Composed preview · what the agent receives")
                    Spacer()
                }
                ScrollView {
                    Text(composedText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 240)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            }
        }
    }

    private var templatesCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Templates")
                Text("Replace the body with a starter. Your current Standing Orders are NOT auto-archived — copy them first if you want to keep a record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(StandingOrdersStore.Template.allCases, id: \.self) { t in
                        Button {
                            draft = t.body
                            selectedTemplate = t
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t.label).font(.subheadline).fontWeight(.semibold)
                                Text(snippet(of: t.body))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                selectedTemplate == t
                                    ? NotionPalette.purple.opacity(0.10)
                                    : Color.black.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(
                                        selectedTemplate == t
                                            ? NotionPalette.purple.opacity(0.35)
                                            : Color.white.opacity(0.10),
                                        lineWidth: 0.5
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        BridgeGlassCard {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message).font(.callout)
                Spacer()
            }
        }
    }

    // MARK: - Logic

    private var composedText: String {
        let body = draft.isEmpty ? (snapshot?.markdown ?? "") : draft
        let composed = StandingOrdersComposer.compose(
            standingOrders: body,
            skills: cachedRoutingSkills()
        )
        return composed.text
    }

    private func snippet(of s: String) -> String {
        // strip heading + take first two non-empty lines
        s.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .prefix(2)
            .joined(separator: " ")
    }

    private func load() async {
        do {
            try StandingOrdersStore.shared.seedIfEmpty()
            let s = try StandingOrdersStore.shared.read()
            await MainActor.run {
                self.snapshot = s
                self.draft = s.markdown
                self.loadError = nil
            }
        } catch {
            await MainActor.run { self.loadError = error.localizedDescription }
        }
    }

    private func save() async {
        guard let s = snapshot else { return }
        do {
            let new = try StandingOrdersStore.shared.write(draft, expectedHash: s.hash)
            await MainActor.run {
                self.snapshot = new
                self.saveMessage = "Saved · \(new.estimatedTokens) tokens"
                self.saveIsError = false
            }
        } catch {
            await MainActor.run {
                self.saveMessage = error.localizedDescription
                self.saveIsError = true
            }
        }
    }

    /// Snapshot of routing skills resolved at load time. Returns the
    /// in-memory copy populated by `.task`; the composer is pure and
    /// re-renders when this state updates. The cache pipeline itself
    /// lives in `SkillsCacheReader/Writer`.
    private func cachedRoutingSkills() -> [RoutingSkillSummary] {
        cachedRouting
    }

    /// v3.7·1: Read every parent in the on-disk skills cache, map it to
    /// the routing-summary shape the composer expects. The cache file
    /// itself only carries the Notion-source parent identity + child
    /// roll-up — triggers/anti-triggers/domain come from the
    /// `SkillsManager` user-config so an operator's per-skill metadata
    /// (which never leaves UserDefaults) is preserved. Cache misses
    /// degrade to "no specialists" silently.
    private func refreshCachedRouting() async {
        // Snapshot SkillsManager on the main actor (it's @MainActor).
        let manager = await MainActor.run { SkillsManager() }
        let parents = await SkillsCacheReader.shared.readAll()
        let parentByName: [String: CachedParent] = Dictionary(
            uniqueKeysWithValues: parents.map { ($0.parentTitle.lowercased(), $0) }
        )
        let summaries: [RoutingSkillSummary] = await MainActor.run {
            manager.routingSkillsForDiscovery.map { skill in
                // The cache entry is keyed by parent title (matches the
                // skill name); fall back to the skill metadata so a
                // routing entry never disappears just because the cache
                // hasn't been refreshed yet.
                let cached = parentByName[skill.name.lowercased()]
                let summary = skill.summary.isEmpty
                    ? (cached?.parentTitle ?? skill.name)
                    : skill.summary
                return RoutingSkillSummary(
                    slug: skill.name.lowercased().replacingOccurrences(of: " ", with: "-"),
                    name: skill.name,
                    domain: nil,
                    maturity: nil,
                    description: summary,
                    triggers: skill.triggerPhrases,
                    antiTriggers: skill.antiTriggerPhrases
                )
            }
        }
        await MainActor.run {
            self.cachedRouting = summaries
        }
    }
}
