// SkillExposureAuthorityTests.swift — Runtime enrollment/exposure contract

import Foundation
import MCP
import TheBridgeLib

private let exposureNow = Date(timeIntervalSince1970: 1_785_196_800) // 2026-07-28T00:00:00Z; fixed
private let exposureUUIDA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let exposureUUIDB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

private func exposureSchema() -> [String: String] {
    SkillExposureCompiler.requiredSchema
}

private func exposureRow(
    id: String = exposureUUIDA,
    name: String = "Alpha",
    slug: String = "alpha",
    status: String? = "Testing",
    maturity: String? = "Stable",
    date: Date? = nil,
    desired: SkillRuntimeExposure? = .standard
) -> SkillRegistryExposureRow {
    .init(notionPageUUID: id, displayName: name, slug: slug,
          status: status, maturity: maturity, deprecationDate: date,
          desiredExposure: desired, url: "https://www.notion.so/\(id)",
          notionLastEditedTime: "2026-07-28T00:00:00.000Z")
}

private func exposureSnapshot(
    rows: [SkillRegistryExposureRow] = [exposureRow()],
    schema: [String: String] = exposureSchema(),
    complete: Bool = true
) -> SkillRegistryExposureSnapshot {
    .init(snapshotID: "snapshot-1", capturedAt: exposureNow,
          schemaColumns: schema, paginationComplete: complete, rows: rows)
}

private func baseline(_ exposure: SkillRuntimeExposure = .standard,
                      id: String = exposureUUIDA,
                      name: String = "Alpha") -> SkillExposureBaselineEntry {
    .init(notionPageUUID: id, displayName: name, exposure: exposure)
}

private func approval(previous: SkillRuntimeExposure?, requested: SkillRuntimeExposure,
                      id: String = exposureUUIDA) -> SkillExposureApproval {
    .init(id: "approval-1", kind: .routeReceipt, notionPageUUID: id,
          previousExposure: previous, requestedExposure: requested,
          routeID: "R4", authorizedAt: exposureNow)
}

private func compile(
    snapshot: SkillRegistryExposureSnapshot,
    previous: SkillRuntimeGeneration? = nil,
    baseline entries: [SkillExposureBaselineEntry] = [],
    approvals: [SkillExposureApproval] = [],
    denylist: Set<String> = [],
    publish: Bool = false
) -> SkillExposureCompilationResult {
    SkillExposureCompiler.compile(snapshot: snapshot, previousGeneration: previous,
        baseline: entries, approvals: approvals, emergencyDenylist: denylist,
        requireReviewedPublishedRows: publish, now: exposureNow)
}

private func publishedGeneration(
    exposure: SkillRuntimeExposure = .routing,
    compiledAt: Date = exposureNow,
    id: String = exposureUUIDA,
    generationID: String = "generation-1"
) -> SkillRuntimeGeneration {
    .init(generationID: generationID, snapshotID: "snapshot-1",
          compilerVersion: "1.0.0", compiledAt: compiledAt,
          entries: [.init(notionPageUUID: id, displayName: "Alpha", slug: "alpha",
                          desiredExposure: exposure, publishedExposure: exposure,
                          lifecycleOverrideReason: nil, approvalID: "approval-1",
                          notionLastEditedTime: "2026-07-28T00:00:00.000Z",
                          url: "https://www.notion.so/\(id)")])
}

private func generationWithEntries(
    _ items: [(id: String, name: String)],
    compiledAt: Date = exposureNow,
    generationID: String = "generation-purge"
) -> SkillRuntimeGeneration {
    .init(generationID: generationID, snapshotID: "snapshot-1",
          compilerVersion: "1.0.0", compiledAt: compiledAt,
          entries: items.map { item in
              .init(notionPageUUID: item.id, displayName: item.name, slug: item.name,
                    desiredExposure: .standard, publishedExposure: .standard,
                    lifecycleOverrideReason: nil, approvalID: "approval-1",
                    notionLastEditedTime: "2026-07-28T00:00:00.000Z",
                    url: "https://www.notion.so/\(item.id)")
          })
}

private func restoreSkillsDefaults(_ prior: Data?) {
    if let prior {
        UserDefaults.standard.set(prior, forKey: BridgeDefaults.skills)
    } else {
        UserDefaults.standard.removeObject(forKey: BridgeDefaults.skills)
    }
}

private func statusProperty(_ key: String, _ value: String) -> [String: Any] {
    [key: ["type": key == "Status" ? "status" : "select",
           key == "Status" ? "status" : "select": ["name": value]]]
}

private func dateProperty(_ value: String) -> [String: Any] {
    ["Deprecation Date": ["type": "date", "date": ["start": value]]]
}

func runSkillExposureAuthorityTests() async {
    print("\n🔐 Skill Runtime Exposure Authority")

    await test("exposure compiler blocks incomplete pagination") {
        let result = compile(snapshot: exposureSnapshot(complete: false))
        try expect(result.candidate == nil, "incomplete snapshot must not compile")
        try expect(result.errors == ["snapshot_incomplete_pagination"], "wrong error: \(result.errors)")
    }

    await test("exposure compiler blocks missing Runtime Exposure schema") {
        var schema = exposureSchema()
        schema.removeValue(forKey: "Runtime Exposure")
        let result = compile(snapshot: exposureSnapshot(schema: schema))
        try expect(result.candidate == nil, "missing required column must block")
        try expect(result.errors.contains("schema_missing:Runtime Exposure"), "missing schema reason absent")
    }

    await test("missing Deprecation Date does not emit schema_missing and does not block solely for that") {
        var schema = exposureSchema()
        schema.removeValue(forKey: "Deprecation Date")
        let result = compile(
            snapshot: exposureSnapshot(rows: [exposureRow(desired: .standard)], schema: schema),
            baseline: [baseline(.standard)]
        )
        try expect(!result.errors.contains("schema_missing:Deprecation Date"),
                   "optional column must not hard-fail: \(result.errors)")
        try expect(result.errors.isEmpty,
                   "missing Deprecation Date must not be the sole blocker: \(result.errors)")
        try expect(result.candidate != nil, "compile must proceed without Deprecation Date")
        try expect(result.candidate?.entry(pageID: exposureUUIDA)?.publishedExposure == .standard,
                   "unchanged Standard row must compile")
    }

    await test("missing Deprecation Date emits schema_optional_missing warning") {
        var schema = exposureSchema()
        schema.removeValue(forKey: "Deprecation Date")
        let result = compile(
            snapshot: exposureSnapshot(rows: [exposureRow(desired: .standard)], schema: schema),
            baseline: [baseline(.standard)]
        )
        try expect(
            result.warnings.contains("\(SkillExposureCompiler.optionalSchemaMissingPrefix)Deprecation Date"),
            "optional missing warning absent: \(result.warnings)"
        )
    }

    await test("Unreviewed preserves baseline in shadow mode") {
        let result = compile(snapshot: exposureSnapshot(rows: [exposureRow(desired: nil)]),
                             baseline: [baseline(.routing)])
        let entry = result.candidate?.entry(pageID: exposureUUIDA)
        try expect(entry?.publishedExposure == .routing, "shadow must preserve known-good exposure")
        try expect(result.warnings.contains(where: { $0.hasPrefix("unreviewed_preserved:") }), "warning absent")
    }

    await test("Unreviewed blocks publication for a published row") {
        let result = compile(snapshot: exposureSnapshot(rows: [exposureRow(desired: nil)]),
                             baseline: [baseline(.routing)], publish: true)
        try expect(result.candidate == nil, "publication must block until the row is reviewed")
        try expect(result.errors.contains(where: { $0.hasPrefix("published_row_unreviewed:") }), "review error absent")
    }

    await test("future deprecation date does not retire early") {
        let future = exposureNow.addingTimeInterval(86_400)
        let result = compile(snapshot: exposureSnapshot(rows: [exposureRow(date: future, desired: .routing)]),
                             baseline: [baseline(.routing)])
        try expect(result.candidate?.entry(pageID: exposureUUIDA)?.publishedExposure == .routing,
                   "future deprecation must remain active")
    }

    await test("effective deprecation date forces Off without approval") {
        let past = exposureNow.addingTimeInterval(-86_400)
        let result = compile(snapshot: exposureSnapshot(rows: [exposureRow(date: past, desired: .routing)]),
                             baseline: [baseline(.routing)])
        try expect(result.candidate?.entry(pageID: exposureUUIDA) == nil, "retired row must be absent")
        try expect(result.changes.contains(where: { $0.contains("deprecation_date_effective") }), "retirement reason absent")
    }

    await test("Revoked and Desolved force Off") {
        let revoked = exposureRow(id: exposureUUIDA, status: "Revoked", desired: .routing)
        let desolved = exposureRow(id: exposureUUIDB, name: "Beta", slug: "beta",
                                   maturity: "Desolved", desired: .standard)
        let result = compile(snapshot: exposureSnapshot(rows: [revoked, desolved]),
                             baseline: [baseline(.routing), baseline(.standard, id: exposureUUIDB, name: "Beta")])
        try expect(result.candidate?.entries.isEmpty == true, "both retired rows must be excluded")
        try expect(result.changes.count == 2, "expected two removal changes")
    }

    await test("new Standard exposure requires route authorization") {
        let result = compile(snapshot: exposureSnapshot())
        try expect(result.candidate == nil, "unapproved enrollment must block")
        try expect(result.errors.contains(where: { $0.hasPrefix("approval_required:") }), "approval error absent")
    }

    await test("approved expansion publishes requested exposure") {
        let result = compile(snapshot: exposureSnapshot(), approvals: [approval(previous: nil, requested: .standard)])
        try expect(result.candidate?.entry(pageID: exposureUUIDA)?.publishedExposure == .standard,
                   "approved Standard exposure not compiled")
    }

    await test("Routing to Command is an authorization-gated surface switch") {
        let row = exposureRow(desired: .command)
        let blocked = compile(snapshot: exposureSnapshot(rows: [row]), baseline: [baseline(.routing)])
        try expect(blocked.candidate == nil, "surface switch must block without approval")
        let allowed = compile(snapshot: exposureSnapshot(rows: [row]), baseline: [baseline(.routing)],
                              approvals: [approval(previous: .routing, requested: .command)])
        try expect(allowed.candidate?.entry(pageID: exposureUUIDA)?.publishedExposure == .command,
                   "approved surface switch failed")
    }

    await test("orphaned baseline identity blocks cutover") {
        let result = compile(snapshot: exposureSnapshot(rows: []), baseline: [baseline()])
        try expect(result.candidate == nil, "orphan must block")
        try expect(result.errors.contains(where: { $0.hasPrefix("orphan_local_skill:") }), "orphan reason absent")
    }

    await test("explicit orphan purge removes named UUID from local and published") {
        let prior = UserDefaults.standard.data(forKey: BridgeDefaults.skills)
        defer { restoreSkillsDefaults(prior) }
        UserDefaults.standard.removeObject(forKey: BridgeDefaults.skills)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-orphan-purge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)

        let purgeID = SkillExposureIdentity.normalize("e7dddd02-c340-4515-80eb-f6a6947d3313")
        let keepID = exposureUUIDB
        let generation = generationWithEntries([
            (purgeID, "block-planning"),
            (keepID, "Beta")
        ])
        _ = try await store.stage(generation)
        _ = try await store.promote(generationID: generation.generationID)
        SkillRuntimeProjectionPublisher.apply(generation)

        let outcome = try await SkillExposureOrphanPurger.apply(
            pageIDs: [purgeID],
            generationStore: store
        )
        try expect(outcome.purgedLocal == [purgeID], "local purge missed: \(outcome.purgedLocal)")
        try expect(outcome.purgedPublished == [purgeID], "published purge missed: \(outcome.purgedPublished)")
        try expect(outcome.held.isEmpty, "named non-HOLD must not be held")

        let published = await store.activeGeneration()
        try expect(published?.entry(pageID: purgeID) == nil, "published still has purged UUID")
        try expect(published?.entry(pageID: keepID) != nil, "unrelated published entry was dropped")

        let local = await MainActor.run {
            SkillExposureBaselineEntry.fromSkillsManager(SkillsManager())
        }
        try expect(!local.contains(where: { $0.notionPageUUID == purgeID }), "local still has purged UUID")
        try expect(local.contains(where: { $0.notionPageUUID == keepID }), "unrelated local skill was dropped")
    }

    await test("generic orphan sweep skips outreach-dispatch HOLD") {
        let prior = UserDefaults.standard.data(forKey: BridgeDefaults.skills)
        defer { restoreSkillsDefaults(prior) }
        UserDefaults.standard.removeObject(forKey: BridgeDefaults.skills)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-orphan-hold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)

        let fleet = SkillExposureOrphanPurge.fleetOrphans20260904
        let hold = SkillExposureOrphanPurge.outreachDispatchHoldPageID
        let generation = generationWithEntries(fleet.map { (SkillExposureIdentity.normalize($0.pageID), $0.slug) })
        _ = try await store.stage(generation)
        _ = try await store.promote(generationID: generation.generationID)
        SkillRuntimeProjectionPublisher.apply(generation)

        let requested = fleet.map(\.pageID)
        try expect(
            !SkillExposureOrphanPurge.admittedForSweep(requested).contains(hold),
            "generic sweep helper must exclude outreach-dispatch"
        )

        let outcome = try await SkillExposureOrphanPurger.apply(
            pageIDs: requested,
            generationStore: store
        )
        try expect(outcome.held == [hold], "HOLD must be reported, got \(outcome.held)")
        try expect(!outcome.purgedLocal.contains(hold), "HOLD must not be purged from local")
        try expect(!outcome.purgedPublished.contains(hold), "HOLD must not be purged from published")
        try expect(outcome.purgedLocal.count == 5, "five non-HOLD locals, got \(outcome.purgedLocal)")
        try expect(outcome.purgedPublished.count == 5, "five non-HOLD published, got \(outcome.purgedPublished)")

        let published = await store.activeGeneration()
        try expect(published?.entry(pageID: hold) != nil, "outreach-dispatch must remain published")
        let local = await MainActor.run {
            SkillExposureBaselineEntry.fromSkillsManager(SkillsManager())
        }
        try expect(local.contains(where: { $0.notionPageUUID == hold }),
                   "outreach-dispatch must remain local")
        try expect(local.count == 1, "only HOLD should remain locally, got \(local.map(\.displayName))")
    }

    await test("degraded generation keeps exact fetch but suppresses ambient surfaces") {
        let stale = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-25 * 3600))
        let gate = SkillRuntimeExposureGate(generation: stale)
        try expect(gate.allows(pageID: exposureUUIDA, surface: .exactFetch, now: exposureNow), "exact fetch should survive")
        try expect(gate.allows(pageID: exposureUUIDA, surface: .bodyCache, now: exposureNow), "body cache should survive")
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .routing, now: exposureNow), "routing must be suppressed")
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .command, now: exposureNow), "command must be suppressed")
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .specialist, now: exposureNow), "specialist must be suppressed")
    }

    await test("emergency denylist reduces every runtime surface") {
        let gate = SkillRuntimeExposureGate(generation: publishedGeneration(), emergencyDenylist: [exposureUUIDA])
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .exactFetch, now: exposureNow), "denylist must block exact fetch")
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .routing, now: exposureNow), "denylist must block routing")
    }

    await test("generation store stages, promotes, and reads back atomically") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        // Reconciliation timestamps normally carry fractional seconds. The
        // persisted generation must preserve that precision or exact staged
        // read-back verification rejects an otherwise valid publication.
        let generation = publishedGeneration(
            compiledAt: Date(timeIntervalSince1970: exposureNow.timeIntervalSince1970 + 0.875123456)
        )
        _ = try await store.stage(generation)
        try expect(await store.activeGeneration() == nil, "staging must not activate")
        _ = try await store.promote(generationID: generation.generationID)
        try expect(await store.activeGeneration() == generation, "promoted generation failed read-back")
    }

    await test("routing snapshot is healthy only with a fresh non-empty Runtime Exposure projection") {
        let row: Value = .object(["name": .string("Alpha"), "source": .string("notion")])
        let freshGate = SkillRuntimeExposureGate(generation: publishedGeneration())
        let healthy = runtimeRoutingSnapshotForTesting(items: [row], gate: freshGate, now: exposureNow)
        try expect(healthy.metadata.status == .healthy)
        try expect(healthy.metadata.source == .runtimeExposureGeneration)
        try expect(healthy.metadata.snapshotID == "generation-1")
        try expect(healthy.metadata.count == 1)
        try expect(healthy.skills.count == 1)

        let empty = runtimeRoutingSnapshotForTesting(items: [], gate: freshGate, now: exposureNow)
        try expect(empty.metadata.status == .empty, "zero routing entries must never be healthy")
        try expect(empty.metadata.count == 0)

        let publishedLease = SkillRuntimeExposureGate(
            generation: publishedGeneration(),
            freshnessRenewedAt: exposureNow
        )
        let publishedSnap = runtimeRoutingSnapshotForTesting(items: [row], gate: publishedLease, now: exposureNow)
        try expect(publishedSnap.metadata.reason == "verified_active_runtime_exposure_generation",
                   "publish lease at compiledAt must not look like a shadow renew")

        let shadowLease = SkillRuntimeExposureGate(
            generation: publishedGeneration(),
            freshnessRenewedAt: exposureNow.addingTimeInterval(60)
        )
        let shadowSnap = runtimeRoutingSnapshotForTesting(items: [row], gate: shadowLease, now: exposureNow)
        try expect(shadowSnap.metadata.reason == "verified_unchanged_shadow_renewed_freshness")
    }

    await test("stale Runtime Exposure suppresses routing and reports degraded evidence") {
        let row: Value = .object(["name": .string("Alpha")])
        let stale = SkillRuntimeExposureGate(
            generation: publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-25 * 3600))
        )
        let snapshot = runtimeRoutingSnapshotForTesting(items: [row], gate: stale, now: exposureNow)
        try expect(snapshot.metadata.status == .degraded)
        try expect(snapshot.metadata.count == 0, "suppressed routing must report the effective zero count")
        try expect(snapshot.skills.isEmpty, "degraded ambient routing must fail closed")
        try expect(snapshot.metadata.reason == "runtime_exposure_freshness_expired")
    }

    await test("unchanged complete shadow renews freshness without publishing a generation") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-renewal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let staleGeneration = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-48 * 3600))
        _ = try await store.stage(staleGeneration)
        _ = try await store.promote(generationID: staleGeneration.generationID)
        let receipt = SkillExposureReconciliationReceipt(
            mode: .shadow,
            outcome: .shadowReady,
            attemptedAt: exposureNow,
            snapshotID: staleGeneration.snapshotID,
            candidateGenerationID: "unpublished-candidate",
            activeGenerationID: staleGeneration.generationID,
            errors: [],
            warnings: [],
            changes: []
        )
        try await store.writeReceipt(receipt)
        guard case .active(let gate) = await store.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(!gate.isDegraded(now: exposureNow), "unchanged shadow must renew freshness")
        try expect(gate.freshnessRenewedAt == exposureNow)
        try expect(await store.activeGenerationID() == staleGeneration.generationID,
                   "shadow renewal must not activate its candidate")
    }

    await test("unchanged shadow renews freshness when Notion snapshot hash drifts without exposure changes") {
        // Live failure mode (build 89 pilot): shadowReady + changes=[] but
        // receipt.snapshotID != active generation.snapshotID because the
        // registry hash includes notionLastEditedTime.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-renewal-drift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let staleGeneration = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-48 * 3600))
        _ = try await store.stage(staleGeneration)
        _ = try await store.promote(generationID: staleGeneration.generationID)
        try await store.writeReceipt(.init(
            mode: .shadow,
            outcome: .shadowReady,
            attemptedAt: exposureNow,
            snapshotID: "2d19aa6a333c259b", // ≠ staleGeneration.snapshotID
            candidateGenerationID: "9e3da411-634c-4b23-adc3-3e87a432ea1a",
            activeGenerationID: staleGeneration.generationID,
            errors: [],
            warnings: [],
            changes: []
        ))
        guard case .active(let gate) = await store.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(!gate.isDegraded(now: exposureNow),
                   "empty exposure changes must renew even when snapshot hash drifted")
        try expect(gate.freshnessRenewedAt == exposureNow)
        try expect(await store.activeGenerationID() == staleGeneration.generationID)
    }

    await test("changed shadow does not renew freshness and still requires publish") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-changed-shadow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let staleGeneration = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-48 * 3600))
        _ = try await store.stage(staleGeneration)
        _ = try await store.promote(generationID: staleGeneration.generationID)
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .shadowReady, attemptedAt: exposureNow,
            snapshotID: staleGeneration.snapshotID,
            candidateGenerationID: "changed-unpublished-candidate",
            activeGenerationID: staleGeneration.generationID,
            errors: [], warnings: [], changes: ["exposure:Alpha:Routing->Standard"]
        ))
        guard case .active(let gate) = await store.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(gate.isDegraded(now: exposureNow), "a changed shadow must not renew active policy")
        try expect(gate.freshnessRenewedAt == nil)
        try expect(await store.activeGenerationID() == staleGeneration.generationID)
    }

    await test("failed shadow after a renewing lease keeps freshness and latestReceipt splits") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-lease-failed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let staleGeneration = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-48 * 3600))
        _ = try await store.stage(staleGeneration)
        _ = try await store.promote(generationID: staleGeneration.generationID)
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .shadowReady, attemptedAt: exposureNow,
            snapshotID: staleGeneration.snapshotID,
            candidateGenerationID: "unpublished-candidate",
            activeGenerationID: staleGeneration.generationID,
            errors: [], warnings: [], changes: []
        ))
        let failedAt = exposureNow.addingTimeInterval(60)
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .failed, attemptedAt: failedAt,
            snapshotID: nil, candidateGenerationID: nil,
            activeGenerationID: staleGeneration.generationID,
            errors: ["reconciliation_failed:offline"], warnings: [], changes: []
        ))
        guard case .active(let gate) = await store.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(!gate.isDegraded(now: exposureNow.addingTimeInterval(120)),
                   "a later failed shadow must not erase a good lease")
        try expect(gate.freshnessRenewedAt == exposureNow)
        let latest = await store.latestReceipt()
        try expect(latest?.outcome == .failed, "latestReceipt must remain the last attempt")
        let lease = await store.freshnessLease()
        try expect(lease?.generationID == staleGeneration.generationID)
        try expect(lease?.renewedAt == exposureNow)
    }

    await test("changed shadow after a renewing lease does not delete the lease") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-lease-changed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let staleGeneration = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-48 * 3600))
        _ = try await store.stage(staleGeneration)
        _ = try await store.promote(generationID: staleGeneration.generationID)
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .shadowReady, attemptedAt: exposureNow,
            snapshotID: staleGeneration.snapshotID,
            candidateGenerationID: "unpublished-candidate",
            activeGenerationID: staleGeneration.generationID,
            errors: [], warnings: [], changes: []
        ))
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .shadowReady,
            attemptedAt: exposureNow.addingTimeInterval(30),
            snapshotID: staleGeneration.snapshotID,
            candidateGenerationID: "changed-unpublished-candidate",
            activeGenerationID: staleGeneration.generationID,
            errors: [], warnings: [], changes: ["exposure:Alpha:Routing->Standard"]
        ))
        guard case .active(let gate) = await store.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(gate.freshnessRenewedAt == exposureNow, "changed shadow must not update or delete the lease")
        try expect(await store.latestReceipt()?.changes == ["exposure:Alpha:Routing->Standard"])
    }

    await test("freshness lease is generation-keyed across promote") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-lease-gen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let genA = publishedGeneration(
            compiledAt: exposureNow.addingTimeInterval(-48 * 3600),
            generationID: "generation-a"
        )
        let genB = publishedGeneration(
            compiledAt: exposureNow.addingTimeInterval(-48 * 3600),
            generationID: "generation-b"
        )
        _ = try await store.stage(genA)
        _ = try await store.promote(generationID: genA.generationID)
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .shadowReady, attemptedAt: exposureNow,
            snapshotID: genA.snapshotID, candidateGenerationID: "cand-a",
            activeGenerationID: genA.generationID,
            errors: [], warnings: [], changes: []
        ))
        _ = try await store.stage(genB)
        _ = try await store.promote(generationID: genB.generationID)
        guard case .active(let gate) = await store.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(gate.freshnessRenewedAt == nil, "gen B must ignore gen A's lease")
        try expect(gate.isDegraded(now: exposureNow), "stale gen B without its own lease must degrade")
    }

    await test("successful publish realigns freshness lease without a follow-up shadow") {
        // #279: after publish, status showed the new activeGenerationId /
        // published receipt but freshnessLease still pointed at the prior
        // shadow. LIVE verify that checks lease.generationId === active
        // generation then false-FAILS a clean publish.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-lease-publish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let prior = publishedGeneration(
            compiledAt: exposureNow.addingTimeInterval(-48 * 3600),
            generationID: "ff2db121-prior-shadow-generation"
        )
        let published = publishedGeneration(
            compiledAt: exposureNow,
            generationID: "6c00f3e1-published-generation"
        )
        _ = try await store.stage(prior)
        _ = try await store.promote(generationID: prior.generationID)
        let priorShadow = SkillExposureReconciliationReceipt(
            receiptID: "9f4c83d9-prior-shadow-receipt",
            mode: .shadow, outcome: .shadowReady,
            attemptedAt: exposureNow.addingTimeInterval(-3600),
            snapshotID: prior.snapshotID,
            candidateGenerationID: "unpublished-candidate",
            activeGenerationID: prior.generationID,
            errors: [], warnings: [], changes: []
        )
        try await store.writeReceipt(priorShadow)
        try expect(await store.freshnessLease()?.generationID == prior.generationID)
        try expect(await store.freshnessLease()?.receiptID == priorShadow.receiptID)

        _ = try await store.stage(published)
        _ = try await store.promote(generationID: published.generationID)
        let publishReceipt = SkillExposureReconciliationReceipt(
            receiptID: "27eadcdc-publish-receipt",
            mode: .publish, outcome: .published,
            attemptedAt: exposureNow,
            snapshotID: published.snapshotID,
            candidateGenerationID: published.generationID,
            activeGenerationID: published.generationID,
            errors: [], warnings: [], changes: []
        )
        try await store.writeReceipt(publishReceipt)

        let lease = await store.freshnessLease()
        try expect(lease?.generationID == published.generationID,
                   "publish must set lease.generationId to the activated generation")
        try expect(lease?.receiptID == publishReceipt.receiptID,
                   "publish must set lease.receiptId to the publish receipt")
        try expect(lease?.renewedAt == exposureNow)
        try expect(await store.activeGenerationID() == published.generationID)
        try expect(await store.latestReceipt()?.outcome == .published)
        guard case .active(let gate) = await store.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(gate.freshnessRenewedAt == exposureNow,
                   "publish lease must renew freshness for the new generation")
        try expect(!gate.isDegraded(now: exposureNow))
    }

    await test("publish with exposure changes still sets the freshness lease") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-lease-publish-changes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let prior = publishedGeneration(
            compiledAt: exposureNow.addingTimeInterval(-48 * 3600),
            generationID: "generation-prior"
        )
        let published = publishedGeneration(
            compiledAt: exposureNow,
            generationID: "generation-published"
        )
        _ = try await store.stage(prior)
        _ = try await store.promote(generationID: prior.generationID)
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .shadowReady,
            attemptedAt: exposureNow.addingTimeInterval(-3600),
            snapshotID: prior.snapshotID, candidateGenerationID: "cand-prior",
            activeGenerationID: prior.generationID,
            errors: [], warnings: [], changes: []
        ))
        _ = try await store.stage(published)
        _ = try await store.promote(generationID: published.generationID)
        try await store.writeReceipt(.init(
            receiptID: "publish-with-changes",
            mode: .publish, outcome: .published, attemptedAt: exposureNow,
            snapshotID: published.snapshotID,
            candidateGenerationID: published.generationID,
            activeGenerationID: published.generationID,
            errors: [], warnings: [],
            changes: ["exposure:Alpha:Routing->Standard"]
        ))
        let lease = await store.freshnessLease()
        try expect(lease?.generationID == published.generationID,
                   "changed publish still activates a verified generation")
        try expect(lease?.receiptID == "publish-with-changes")
    }

    await test("failed publish does not move or erase a prior freshness lease") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-lease-publish-failed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let prior = publishedGeneration(
            compiledAt: exposureNow.addingTimeInterval(-48 * 3600),
            generationID: "generation-prior"
        )
        _ = try await store.stage(prior)
        _ = try await store.promote(generationID: prior.generationID)
        try await store.writeReceipt(.init(
            receiptID: "good-shadow",
            mode: .shadow, outcome: .shadowReady, attemptedAt: exposureNow,
            snapshotID: prior.snapshotID, candidateGenerationID: "cand",
            activeGenerationID: prior.generationID,
            errors: [], warnings: [], changes: []
        ))
        try await store.writeReceipt(.init(
            mode: .publish, outcome: .failed,
            attemptedAt: exposureNow.addingTimeInterval(30),
            snapshotID: nil, candidateGenerationID: nil,
            activeGenerationID: prior.generationID,
            errors: ["reconciliation_failed:publicationVerificationFailed"],
            warnings: [], changes: []
        ))
        let lease = await store.freshnessLease()
        try expect(lease?.generationID == prior.generationID)
        try expect(lease?.receiptID == "good-shadow")
        try expect(lease?.renewedAt == exposureNow)
        try expect(await store.latestReceipt()?.outcome == .failed)
    }

    await test("upgrade seeds lease from a published receipt when the lease file is missing") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-lease-seed-publish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let published = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-48 * 3600))
        _ = try await store.stage(published)
        _ = try await store.promote(generationID: published.generationID)
        try await store.writeReceipt(.init(
            receiptID: "publish-seed",
            mode: .publish, outcome: .published, attemptedAt: exposureNow,
            snapshotID: published.snapshotID,
            candidateGenerationID: published.generationID,
            activeGenerationID: published.generationID,
            errors: [], warnings: [], changes: []
        ))
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .failed, attemptedAt: exposureNow.addingTimeInterval(90),
            snapshotID: nil, candidateGenerationID: nil,
            activeGenerationID: published.generationID,
            errors: ["reconciliation_failed:offline"], warnings: [], changes: []
        ))
        let leaseURL = root.appendingPathComponent("freshness-lease.json")
        try FileManager.default.removeItem(at: leaseURL)
        let reloaded = SkillRuntimeGenerationStore(baseDirectory: root)
        guard case .active(let gate) = await reloaded.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(gate.freshnessRenewedAt == exposureNow,
                   "upgrade must seed from the published receipt, not failed latest-receipt")
        try expect(await reloaded.freshnessLease()?.receiptID == "publish-seed")
        try expect(await reloaded.freshnessLease()?.generationID == published.generationID)
    }

    await test("upgrade seeds lease from receipts when the lease file is missing") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-lease-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let staleGeneration = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-48 * 3600))
        _ = try await store.stage(staleGeneration)
        _ = try await store.promote(generationID: staleGeneration.generationID)
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .shadowReady, attemptedAt: exposureNow,
            snapshotID: staleGeneration.snapshotID,
            candidateGenerationID: "unpublished-candidate",
            activeGenerationID: staleGeneration.generationID,
            errors: [], warnings: [], changes: []
        ))
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .failed, attemptedAt: exposureNow.addingTimeInterval(90),
            snapshotID: nil, candidateGenerationID: nil,
            activeGenerationID: staleGeneration.generationID,
            errors: ["reconciliation_failed:offline"], warnings: [], changes: []
        ))
        let leaseURL = root.appendingPathComponent("freshness-lease.json")
        try FileManager.default.removeItem(at: leaseURL)
        let reloaded = SkillRuntimeGenerationStore(baseDirectory: root)
        guard case .active(let gate) = await reloaded.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(gate.freshnessRenewedAt == exposureNow,
                   "upgrade must seed from the newest qualifying receipt, not failed latest-receipt")
        try expect(await reloaded.latestReceipt()?.outcome == .failed)
        try expect(await reloaded.freshnessLease()?.renewedAt == exposureNow)
    }

    await test("corrupt active generation pointer is explicit missing authority, never legacy fallback") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-corrupt-pointer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"generationID\":\"missing-generation\"}".utf8)
            .write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        guard case .corrupt(let pointerID) = await store.routingAuthority() else {
            throw TestError.assertion("corrupt pointer must not fall back to legacy routing")
        }
        try expect(pointerID == "missing-generation")
    }

    await test("malformed active pointer is explicit missing authority, never legacy fallback") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-malformed-pointer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        guard case .corrupt(let pointerID) = await store.routingAuthority() else {
            throw TestError.assertion("malformed pointer must not fall back to legacy routing")
        }
        try expect(pointerID == "unreadable-active-pointer")
    }

    await test("specialist lifecycle recognizes Revoked, Desolved, and effective dates") {
        try expect(!SpecialistFilter.isActiveSpecialist(properties: statusProperty("Status", "Revoked"), now: exposureNow),
                   "Revoked specialist remained active")
        try expect(!SpecialistFilter.isActiveSpecialist(properties: statusProperty("Maturity", "Desolved"), now: exposureNow),
                   "Desolved specialist remained active")
        try expect(!SpecialistFilter.isActiveSpecialist(properties: dateProperty("2026-07-27"), now: exposureNow),
                   "effective date remained active")
        try expect(SpecialistFilter.isActiveSpecialist(properties: dateProperty("2026-07-29"), now: exposureNow),
                   "future date retired early")
        try expect(SpecialistFilter.isActiveSpecialist(properties: dateProperty("not-a-date"), now: exposureNow),
                   "malformed date must fail open")
    }
}
