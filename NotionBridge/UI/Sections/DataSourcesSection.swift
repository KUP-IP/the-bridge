// DataSourcesSection.swift — Settings → Data Sources page body (the Data-Source
// Registry). PKT-registry · v4 "Liquid Glass, evolved".
//
// Maps the app's logical ENTITIES (Contacts, Jobs, …) onto the Notion data
// sources they live in, and binds each entity's properties by ID so The Bridge's
// cache + CRUD tools have a stable schema to work against. The page is a stack of
// per-entity glass cards over the merged-Connection card/section idiom
// (BridgeGlassCard · BridgeCardLabel · BridgeBadge · BridgeButton · the recessed
// `wellFill` rows), reusing the W1 token ladder verbatim — no hardcoded color.
//
// The headline interaction is PROPOSE → CONFIRM: "Introspect" reads the LIVE
// Notion schema and stages a `Proposal` (drift list + matched-column count)
// WITHOUT persisting; an inline panel then offers Confirm (persist) / Cancel.
// This mirrors the doctrine Preview|Edit→Save gesture on the Connection page —
// nothing touches disk until the operator confirms.
//
// Binds to `DataSourcesViewModel` (same NotionBridgeLib module): `entities`,
// `proposal`, `cacheCounts`, `busy`, `status`, plus `bindingProgress`,
// `proposeIntrospection`, `confirmProposal`, `cancelProposal`, `setTTL`,
// `clearCache`. The VM is owned here as a `@StateObject` and loaded once on
// appear; every store/async call is the VM's — this view is pure presentation.
//
// AX note: the registry section predates a `SettingsSection` enum case, so the
// `BridgeAXID.control(_:_:)` helper (which keys off a case) can't mint these ids.
// They are emitted as plain strings that follow the SAME documented convention —
// `bridge.settings.<section>.<control>`, anchored to `BridgeAXID.root` — so the
// headless AX harness can target them deterministically and they fold into the
// enum the moment the case lands.

import SwiftUI

public struct DataSourcesSection: View {
    @StateObject private var vm = DataSourcesViewModel()

    public init() {}

    /// AX id under the shared `bridge.settings.<section>.<control>` convention
    /// (BridgeShell `BridgeAXID`), pending a `.dataSources` enum case.
    private func ax(_ slug: String) -> String { "\(BridgeAXID.root).datasources.\(slug)" }

    public var body: some View {
        // Hosted inside the Settings detail scroll the composite supplies — a
        // single outer ScrollView so long registries scroll as one column.
        ScrollView {
            VStack(spacing: BridgeTokens.Space.cardGap) {
                headerCard
                ForEach(vm.entities, id: \.key) { entity in
                    entityCard(entity)
                }
            }
            .padding(.horizontal, BridgeTokens.Space.paneH)
            .padding(.top, 4)
            .padding(.bottom, BridgeTokens.Space.paneV)
            .frame(maxWidth: .infinity)
        }
        .background(Color.clear)
        .task { await vm.load() }
    }

    // MARK: - Header (what the registry is + a subtle live status)

    private var headerCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(BridgeTokens.fg3)
                        .accessibilityHidden(true)
                    BridgeCardLabel("Data sources")
                    Spacer(minLength: 8)
                    if vm.busy {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Map entities to your Notion data sources. Bind properties by ID; The Bridge's cache + CRUD tools then work against them.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                if !vm.status.isEmpty {
                    Text(vm.status)
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(ax("status"))
                }
            }
        }
    }

    // MARK: - Per-entity card (binding state + actions + the proposal panel)

    @ViewBuilder
    private func entityCard(_ entity: RegistryEntity) -> some View {
        let progress = vm.bindingProgress(entity.key)
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 11) {
                entityHead(entity, progress: progress)
                entityMeta(entity)
                entityActions(entity)
                if let proposal = vm.proposal, proposal.entityKey == entity.key {
                    proposalPanel(proposal)
                }
            }
        }
        .accessibilityIdentifier(ax("entity"))
    }

    /// Name + the bound/total progress badge (OK when fully bound, else warn).
    private func entityHead(_ entity: RegistryEntity, progress: (bound: Int, total: Int)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entity.displayName)
                .font(BridgeTokens.Typeface.name)
                .foregroundStyle(BridgeTokens.fg1)
                .lineLimit(1)
            if entity.hasBody {
                BridgeBadge("Has body", tone: .info)
            }
            Spacer(minLength: 8)
            BridgeBadge(
                "\(progress.bound)/\(progress.total) bound",
                tone: entity.isFullyBound ? .ok : .warn,
                showsDot: true)
        }
    }

    /// The mono data-source id (truncated) + the cached-row count.
    private func entityMeta(_ entity: RegistryEntity) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let cached = vm.cacheCounts[entity.key] ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "number")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(BridgeTokens.fg5)
                .accessibilityHidden(true)
            Text(entity.dataSourceId)
                .font(BridgeTokens.Typeface.mono)
                .foregroundStyle(BridgeTokens.fg3)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text("\(cached) cached")
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg4)
                .lineLimit(1)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(shape.fill(BridgeTokens.wellFill))
        .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .bridgeBevel(BridgeTokens.bevelInset, radius: 10)
    }

    /// Introspect (propose) · Clear cache · a compact cache-TTL stepper. All
    /// disabled while the VM is busy so a click can't race a pending async call.
    private func entityActions(_ entity: RegistryEntity) -> some View {
        HStack(spacing: 8) {
            BridgeButton("Introspect", systemImage: "arrow.triangle.2.circlepath",
                         variant: .default, isEnabled: !vm.busy) {
                Task { await vm.proposeIntrospection(entity.key) }
            }
            .accessibilityIdentifier(ax("introspect"))

            BridgeButton("Clear cache", systemImage: "trash",
                         variant: .default, isEnabled: !vm.busy) {
                Task { await vm.clearCache(entity.key) }
            }
            .accessibilityIdentifier(ax("clearCache"))

            Spacer(minLength: 8)

            ttlStepper(entity)
        }
    }

    /// Cache TTL stepper (`.cnp`-style well): a leading "TTL" cap, the seconds
    /// value, and −/+ steppers that commit through `setTTL`. Steps on a coarse
    /// ladder so a single tap is a meaningful change, clamped at a 0s floor.
    private func ttlStepper(_ entity: RegistryEntity) -> some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
        let seconds = entity.cacheTTLSeconds
        return HStack(spacing: 8) {
            Text("TTL").bridgeCap().foregroundStyle(BridgeTokens.fg4)
            stepButton("minus", help: "Decrease cache TTL") {
                let next = max(0, seconds - ttlStep(seconds))
                Task { await vm.setTTL(entity.key, seconds: next) }
            }
            Text(ttlLabel(seconds))
                .font(BridgeTokens.Typeface.mono)
                .foregroundStyle(BridgeTokens.fg2)
                .frame(minWidth: 44)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Cache TTL \(seconds) seconds")
            stepButton("plus", help: "Increase cache TTL") {
                let next = seconds + ttlStep(seconds)
                Task { await vm.setTTL(entity.key, seconds: next) }
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
        .background(shape.fill(BridgeTokens.glassControl))
        .overlay(shape.strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
        .bridgeBevel(BridgeTokens.bevelControl, radius: BridgeTokens.Radius.control)
        .accessibilityIdentifier(ax("ttl"))
    }

    private func stepButton(_ glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(vm.busy ? BridgeTokens.fg5 : BridgeTokens.fg3)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(vm.busy)
        .help(help)
    }

    /// Coarse TTL step ladder so taps stay meaningful across the range.
    private func ttlStep(_ seconds: Int) -> Int {
        switch seconds {
        case ..<60:    return 15
        case ..<600:   return 60
        case ..<3600:  return 300
        default:       return 3600
        }
    }

    /// Compact TTL label — seconds under a minute, else `Nm` / `Nh`.
    private func ttlLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    // MARK: - Proposal panel (the propose → confirm review)
    //
    // Shown only while `vm.proposal` targets THIS entity: the live-schema drift
    // lines (a missing-column line goes red, everything else neutral), a clean
    // "Ready — N/N matched" note when fully bound + clean, and Confirm / Cancel.

    private func proposalPanel(_ proposal: DataSourcesViewModel.Proposal) -> some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(BridgeTokens.fg3)
                    .accessibilityHidden(true)
                Text("Proposed binding").bridgeCap().foregroundStyle(BridgeTokens.fg4)
                Spacer(minLength: 8)
                if vm.busy { ProgressView().controlSize(.mini) }
            }

            if proposal.clean && proposal.fullyBound {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.okText)
                    Text("Ready — \(proposal.schemaColumns.count)/\(proposal.schemaColumns.count) matched")
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.okText)
                }
            }

            if proposal.drift.isEmpty {
                if !(proposal.clean && proposal.fullyBound) {
                    Text("No drift — schema matches the current binding.")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(proposal.drift.enumerated()), id: \.offset) { _, line in
                        driftLine(line)
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                BridgeButton("Cancel", variant: .default, isEnabled: !vm.busy) {
                    vm.cancelProposal()
                }
                .accessibilityIdentifier(ax("proposal.cancel"))
                BridgeButton("Confirm", systemImage: "checkmark", variant: .primary, isEnabled: !vm.busy) {
                    Task { _ = await vm.confirmProposal() }
                }
                .accessibilityIdentifier(ax("proposal.confirm"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(shape.fill(BridgeTokens.wellFillDeep))
        .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.input)
        .accessibilityIdentifier(ax("proposal"))
    }

    /// One drift line: a missing-column callout reads as an error (red glyph +
    /// ink); every other line is a neutral bullet.
    @ViewBuilder
    private func driftLine(_ line: String) -> some View {
        let isMissing = line.localizedCaseInsensitiveContains("no column named")
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: isMissing ? "exclamationmark.triangle.fill" : "circle.fill")
                .font(.system(size: isMissing ? 10 : 5))
                .foregroundStyle(isMissing ? BridgeTokens.badText : BridgeTokens.fg5)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(line)
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(isMissing ? BridgeTokens.badText : BridgeTokens.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
