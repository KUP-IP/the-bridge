// RoutingReliabilityTests.swift — routing-reliability wave.
//
// Coverage for the routing-reliability fixes:
//   • SpecialistFilter — doc-page exclusion (changelogs / PRDs / §-sections /
//     test matrices / evolution logs / phase / pruning / duplicate stubs)
//     vs curated specialist titles.
//   • SkillIntentScorer.decide — confident / disambiguate / none classification
//     (the confidence → clarify path).
//   • ClientOverlayStore get/set + composition(clientName:) overlay append.
//   • SkillsModule.routingFooter — sibling-specialist footer shape + nil cases.
//   • DeliveryLog.skillFetched event ingest + skillFetchFields parsing.
//
// All pure / hermetic: SpecialistFilter + scorer are pure; the overlay +
// composition tests run under a per-test tmp HOME via withRoutingTempHome;
// the DeliveryLog tests use an injected hash + resetForTesting (no file I/O).

import Foundation
import MCP
import NotionBridgeLib

func runRoutingReliabilityTests() async {
    print("\n\u{1F9ED} Routing Reliability Tests")

    // MARK: - SpecialistFilter: doc-page exclusion

    await test("Filter: doc-page titles are excluded from specialists") {
        // The audit's doc-page noise must all be filtered out.
        let docPages = [
            "§ 3.2 Architecture",
            "Changelog",
            "v3.7 Change Log",
            "PRD",
            "PRD — Routing v2",
            "Test Matrix",
            "Evolution Log",
            "Phase 1",
            "Phase 2.5 Planning",
            "Pruning Notes",
            "Decision Log",
            "Roadmap",
            "Backlog",
            "Archive (old specialists)",
            "Update (duplicate)",
            "Triage (stub)"
        ]
        for t in docPages {
            try expect(SpecialistFilter.isDocPage(title: t), "expected doc-page: '\(t)'")
            try expect(!SpecialistFilter.isSpecialist(title: t), "doc-page must not be a specialist: '\(t)'")
        }
    }

    await test("Filter: curated specialist titles are kept") {
        let specialists = ["update", "triage", "close", "enrich", "Dedupe Contacts", "session reflow"]
        for t in specialists {
            try expect(SpecialistFilter.isSpecialist(title: t), "expected specialist: '\(t)'")
            try expect(!SpecialistFilter.isDocPage(title: t), "specialist must not be a doc-page: '\(t)'")
        }
    }

    await test("Filter: empty / whitespace title is not a specialist") {
        try expect(SpecialistFilter.isDocPage(title: ""))
        try expect(SpecialistFilter.isDocPage(title: "   "))
        try expect(!SpecialistFilter.isSpecialist(title: ""))
    }

    await test("Filter: 'rephrase' / 'phased' do NOT trip the Phase pattern") {
        // The Phase pattern requires a word boundary + digit, so prose words
        // containing 'phase' must remain specialists.
        try expect(SpecialistFilter.isSpecialist(title: "rephrase the message"))
        try expect(SpecialistFilter.isSpecialist(title: "phased rollout helper"))
        // But a real "Phase 3" page is excluded.
        try expect(SpecialistFilter.isDocPage(title: "Phase 3"))
    }

    // MARK: - SkillIntentScorer.decide (confidence → clarify)

    await test("Decide: clear winner → .confident") {
        let cands = [
            SkillIntentCandidate(name: "update"),
            SkillIntentCandidate(name: "archive-old-projects")
        ]
        let d = SkillIntentScorer.decide(intent: "update", candidates: cands)
        guard case .confident(let s) = d else {
            throw TestError.assertion("expected .confident, got \(d)")
        }
        try expect(s.candidate.name == "update")
        try expect(s.score >= SkillIntentScorer.confidenceThreshold)
    }

    await test("Decide: two near-tied candidates → .disambiguate") {
        // Both are exact-ish matches to overlapping intent tokens, landing in
        // the keyword-overlap band within the disambiguation margin.
        let cands = [
            SkillIntentCandidate(name: "triage stale projects", summary: "triage stale projects"),
            SkillIntentCandidate(name: "triage stale contacts", summary: "triage stale contacts")
        ]
        let d = SkillIntentScorer.decide(intent: "triage stale", candidates: cands)
        guard case .disambiguate(let close) = d else {
            throw TestError.assertion("expected .disambiguate, got \(d)")
        }
        try expect(close.count >= 2, "disambiguation must surface the close candidates")
    }

    await test("Decide: near-tied keyword-overlap candidates → .disambiguate") {
        // Two candidates that both land on the SAME keyword-overlap score
        // (one shared token each) are within the disambiguation margin → the
        // dispatcher must clarify rather than arbitrarily picking one.
        let cands = [
            SkillIntentCandidate(name: "alpha", summary: "handles widgets"),
            SkillIntentCandidate(name: "beta", summary: "handles widgets")
        ]
        let d = SkillIntentScorer.decide(intent: "widgets task", candidates: cands)
        guard case .disambiguate(let close) = d else {
            throw TestError.assertion("equal-scoring candidates must clarify, got \(d)")
        }
        try expect(close.count == 2, "both tied candidates are surfaced")
        try expect(close.allSatisfy { $0.score > 0 }, "surfaced candidates carry a score")
    }

    await test("Decide: no scoring candidate → .none") {
        let cands = [SkillIntentCandidate(name: "update"), SkillIntentCandidate(name: "triage")]
        let d = SkillIntentScorer.decide(intent: "zzqqxx nonsense token", candidates: cands)
        guard case .none = d else {
            throw TestError.assertion("expected .none for a no-signal intent, got \(d)")
        }
    }

    // MARK: - ClientOverlayStore + composition(clientName:)

    await test("Overlay: get/set round-trip is case-insensitive on client name") {
        try await withRoutingTempHome { _ in
            ClientOverlayStore.shared.resetForTesting()
            try expect(ClientOverlayStore.shared.overlay(forClient: "Claude Code") == nil,
                       "no overlay by default")
            ClientOverlayStore.shared.setOverlay("# Extra\n\nbe extra terse", forClient: "Claude Code")
            // Case-insensitive read.
            try expect(ClientOverlayStore.shared.overlay(forClient: "claude code") == "# Extra\n\nbe extra terse")
            // Clearing reverts to nil.
            ClientOverlayStore.shared.setOverlay(nil, forClient: "CLAUDE CODE")
            try expect(ClientOverlayStore.shared.overlay(forClient: "Claude Code") == nil,
                       "nil overlay clears the entry")
        }
    }

    await test("Overlay: empty default → composition byte-identical to no-client") {
        try await withRoutingTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            ClientOverlayStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nuniform")
            let base = StandingOrdersDelivery.composition(clientName: nil)
            let named = StandingOrdersDelivery.composition(clientName: "claude-code")
            try expect(base == named, "no overlay set → identical content for nil and named client")
        }
    }

    await test("Overlay: composition appends the overlay for the named client") {
        try await withRoutingTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            ClientOverlayStore.shared.resetForTesting()
            // Reset the process-global overlay store on the way out too, so
            // this entry can never contaminate a sibling delivery test that
            // composes for a same-named client (UserDefaults is not scoped by
            // the temp HOME override).
            defer { ClientOverlayStore.shared.resetForTesting() }
            _ = try StandingOrdersStore.shared.write("# Orders\n\nbase orders")
            ClientOverlayStore.shared.setOverlay("CLIENT-SPECIFIC NOTE", forClient: "claude-code")

            let other = StandingOrdersDelivery.composition(clientName: "some-other-client")
            try expect(!other.instructionsMarkdown.contains("CLIENT-SPECIFIC NOTE"),
                       "a different client must not see the overlay")

            let named = StandingOrdersDelivery.composition(clientName: "claude-code")
            try expect(named.instructionsMarkdown.contains("CLIENT-SPECIFIC NOTE"),
                       "the named client's instructions must include the overlay")
            try expect(named.instructionsMarkdown.hasSuffix("CLIENT-SPECIFIC NOTE"),
                       "overlay is appended at the tail")
            // The overlay changes content → the content hash diverges.
            try expect(named.contentHash != other.contentHash,
                       "overlay must change the content hash")
        }
    }

    // MARK: - Routing footer (item 3)

    await test("Footer: names sibling specialists and the re-route instruction") {
        let footer = SkillsModule.routingFooterForTesting(
            parentName: "project-keepr",
            currentSpecialistTitle: "update",
            siblingTitles: ["update", "triage", "close"]
        )
        try expect(footer != nil, "footer must be present when siblings exist")
        let f = footer ?? ""
        try expect(f.contains("project-keepr/triage"), "footer names a sibling by path")
        try expect(f.contains("project-keepr/close"), "footer names a sibling by path")
        try expect(!f.contains("project-keepr/update"), "the current specialist is excluded from the siblings")
        try expect(f.contains("fetch_skill('project-keepr', intent:"), "footer carries the re-route instruction")
    }

    await test("Footer: nil when there are no other specialists") {
        // Single specialist that IS the current one → no siblings → no footer.
        try expect(SkillsModule.routingFooterForTesting(
            parentName: "p", currentSpecialistTitle: "only", siblingTitles: ["only"]) == nil)
        // Empty sibling list → no footer.
        try expect(SkillsModule.routingFooterForTesting(
            parentName: "p", currentSpecialistTitle: nil, siblingTitles: []) == nil)
    }

    await test("Footer: parent-body case (no current specialist) lists all siblings") {
        let footer = SkillsModule.routingFooterForTesting(
            parentName: "people-keepr",
            currentSpecialistTitle: nil,
            siblingTitles: ["brief", "enrich"]
        )
        let f = footer ?? ""
        try expect(f.contains("people-keepr/brief"))
        try expect(f.contains("people-keepr/enrich"))
    }

    // MARK: - DeliveryLog.skillFetched (item 5)

    await test("DeliveryLog: skillFetched event ingests with skill + intent") {
        await MainActor.run {
            DeliveryLog.shared.resetForTesting()
            DeliveryLog.shared.recordSkillFetched(
                sessionID: "sess-1", clientName: "claude-code",
                skill: "project-keepr/update", intent: "triage stale projects"
            )
        }
        // The record* hop is an unawaited Task { @MainActor } — give it a turn.
        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await MainActor.run { DeliveryLog.shared.timeline(limit: 10) }
        guard let e = events.first(where: { $0.kind == .skillFetched }) else {
            throw TestError.assertion("expected a skillFetched event in the timeline")
        }
        try expect(e.uri == "project-keepr/update", "skill name/path stored under uri")
        try expect(e.intent == "triage stale projects", "intent stored on the event")
        try expect(e.sessionID == "sess-1")
    }

    await test("DeliveryLog: skillFetchFields parses name + trimmed intent") {
        let (skill, intent) = DeliveryLog.skillFetchFields(from: .object([
            "name": .string("project-keepr"),
            "intent": .string("  triage stale projects  ")
        ]))
        try expect(skill == "project-keepr")
        try expect(intent == "triage stale projects", "intent must be trimmed")

        // Missing intent → nil; blank intent → nil; non-object → empty.
        let (s2, i2) = DeliveryLog.skillFetchFields(from: .object(["name": .string("p")]))
        try expect(s2 == "p" && i2 == nil)
        let (s3, i3) = DeliveryLog.skillFetchFields(from: .object(["name": .string("p"), "intent": .string("   ")]))
        try expect(s3 == "p" && i3 == nil, "whitespace-only intent → nil")
        let (s4, i4) = DeliveryLog.skillFetchFields(from: nil)
        try expect(s4 == "" && i4 == nil)
    }
}

// MARK: - Test fixture helpers (local, not exported)

private func withRoutingTempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("RoutingReliability-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
