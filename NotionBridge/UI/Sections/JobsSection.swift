// JobsSection.swift — Liquid Glass reskin of Settings → Jobs.
// PKT-876 v3.6.1. Per design/jobs.html:
//   - Glass-hero header with active/failing counts
//   - "Last 24 hours" stat strip
//   - Scheduled jobs list (delegates to existing JobsView body, preserved verbatim)
//
// Behavior unchanged — existing JobsView handles all CRUD; this wraps it
// in the shared glass shell.

import SwiftUI

public struct JobsSection: View {
    @State private var jobsSnapshot: [JobRecord] = []
    @State private var statsLoaded = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                statsCard
                jobsListCard
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task { await loadSnapshot() }
        .onReceive(NotificationCenter.default.publisher(for: .jobsDidChange)) { _ in
            Task { await loadSnapshot() }
        }
    }

    // MARK: - Header

    private var header: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .jobs)
        return BridgeSettingsSectionHeader(
            title: spec.title,
            subtitle: spec.subtitle,
            systemImage: spec.systemImage,
            tint: spec.tint
        ) {
            jobsActivityPill
        }
    }

    private var active: Int { jobsSnapshot.filter { $0.status == .active }.count }
    private var paused: Int { jobsSnapshot.filter { $0.status == .paused }.count }

    private var jobsActivityPill: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(active)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.49, green: 0.84, blue: 0.63))
            Text("active")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Stats

    private var statsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Last 24 hours")
                HStack(spacing: 10) {
                    statCell(value: "\(jobsSnapshot.count)", caption: "Total", color: Color.primary)
                    statCell(value: "\(active)", caption: "Active", color: Color(red: 0.49, green: 0.84, blue: 0.63))
                    statCell(value: "\(paused)", caption: "Paused", color: Color(red: 0.96, green: 0.81, blue: 0.49))
                    // v3.6: "Failed" cell removed — failure tracking infra not wired
                    // (was hardcoded "0"). Returns in a dedicated packet alongside
                    // JobStore failure-history derivation.
                }
            }
        }
    }

    @ViewBuilder
    private func statCell(value: String, caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(color)
            Text(caption.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Jobs list (delegates to existing JobsView)

    private var jobsListCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Scheduled jobs")
                JobsView()
                    .frame(minHeight: 360)
            }
        }
    }

    // MARK: - Data

    private func loadSnapshot() async {
        do {
            let all = try await JobStore.shared.listAll(statusFilter: nil)
            await MainActor.run {
                jobsSnapshot = all
                statsLoaded = true
            }
        } catch {
            await MainActor.run { statsLoaded = true }
        }
    }
}
