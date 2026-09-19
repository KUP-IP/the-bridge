// SkillsModuleExposureRegistration.swift — Runtime Exposure operator controls
// TheBridge · Modules · Skills

import Foundation
import MCP

extension SkillsModule {
    /// Register the Runtime Exposure control plane. The desired-state compiler
    /// and generation store remain the publication path; these tools inspect
    /// it, invoke reconciliation, apply a monotonic emergency gate, or drop
    /// named orphans after an explicit SKILLS lifecycle decision.
    static func registerExposurePrimitives(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "skills_exposure_status",
            module: moduleName,
            tier: .open,
            description: "Read Runtime Exposure state: active verified generation, freshness lease (last successful publish or unchanged shadow for that generation), latest reconciliation receipt (last attempt — may disagree with the lease after failed/blocked/changed shadows), enabled migration baseline, degraded status, and emergency denylist. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let store = SkillRuntimeGenerationStore.shared
                let active = await store.activeGeneration()
                let gate = await store.gate()
                let latest = await store.latestReceipt()
                let lease = await store.freshnessLease()
                let denylist = await store.emergencyDenylist().sorted()
                let baseline = await MainActor.run {
                    SkillExposureBaselineEntry.fromSkillsManager(SkillsManager())
                }
                let now = Date()
                let routingSnapshot = await Self.routingSnapshot(now: now)
                var result: [String: Value] = [
                    "active": .bool(active != nil),
                    "activeGenerationId": active.map { .string($0.generationID) } ?? .null,
                    "activeEntryCount": .int(active?.entries.count ?? 0),
                    "compiledAt": active.map { .string(Self.exposureISO8601($0.compiledAt)) } ?? .null,
                    "ageSeconds": active.map { .double(max(0, now.timeIntervalSince($0.compiledAt))) } ?? .null,
                    "freshnessAt": gate.map { .string(Self.exposureISO8601($0.freshnessReferenceDate)) } ?? .null,
                    "freshnessAgeSeconds": gate.map { .double(max(0, now.timeIntervalSince($0.freshnessReferenceDate))) } ?? .null,
                    "degraded": .bool(routingSnapshot.metadata.status == .degraded),
                    "routingSnapshot": routingSnapshot.value,
                    "enabledBaselineCount": .int(baseline.count),
                    "emergencyDenylist": .array(denylist.map(Value.string)),
                    "emergencyDenylistCount": .int(denylist.count),
                    "latestReceipt": latest.map(Self.exposureReceiptValue) ?? .null,
                    "freshnessLease": lease.map { lease in
                        .object([
                            "generationId": .string(lease.generationID),
                            "renewedAt": .string(Self.exposureISO8601(lease.renewedAt)),
                            "receiptId": .string(lease.receiptID)
                        ])
                    } ?? .null
                ]
                if let active {
                    var counts: [String: Int] = [:]
                    for entry in active.entries {
                        counts[entry.publishedExposure.rawValue, default: 0] += 1
                    }
                    result["publishedCounts"] = .object([
                        "Standard": .int(counts[SkillRuntimeExposure.standard.rawValue, default: 0]),
                        "Routing": .int(counts[SkillRuntimeExposure.routing.rawValue, default: 0]),
                        "Command": .int(counts[SkillRuntimeExposure.command.rawValue, default: 0])
                    ])
                }
                return .object(result)
            }
        ))

        await router.register(ToolRegistration(
            name: "skills_exposure_reconcile",
            module: moduleName,
            tier: .notify,
            description: "Run Runtime Exposure reconciliation immediately. mode='shadow' is read-only and writes only a receipt. mode='publish' stages, verifies, projects, and atomically activates a generation; it requires a current SKILLS Keepr routeReceipt. Expansion or Routing↔Command switches additionally require matching approvals.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("shadow"), .string("publish")]),
                        "description": .string("shadow | publish")
                    ]),
                    "approvals": .object([
                        "type": .string("array"),
                        "description": .string("Optional approved exposure expansions/surface switches: [{name,pageId,previousExposure?,requestedExposure,approvalId?}]. previousExposure omitted means Unreviewed."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "name": .object(["type": .string("string")]),
                                "pageId": .object(["type": .string("string")]),
                                "previousExposure": .object(["type": .string("string")]),
                                "requestedExposure": .object(["type": .string("string")]),
                                "approvalId": .object(["type": .string("string")])
                            ]),
                            "required": .array([.string("name"), .string("pageId"), .string("requestedExposure")])
                        ])
                    ]),
                    "routeReceipt": SkillRouteReceiptValidator.schema
                ]),
                "required": .array([.string("mode")])
            ]),
            handler: { arguments in
                let args = Self.unpackArgsObject(arguments)
                guard case .string(let rawMode) = args["mode"],
                      let mode = SkillExposureReconciliationReceipt.Mode(rawValue: rawMode) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skills_exposure_reconcile",
                        reason: "mode must be 'shadow' or 'publish'"
                    )
                }

                let approvalRequests = try Self.parseExposureApprovalRequests(args["approvals"])
                var approvals: [SkillExposureApproval] = []
                if mode == .publish {
                    let expectedTargets = approvalRequests.isEmpty
                        ? ["runtime-exposure"]
                        : approvalRequests.map(\.name)
                    try Self.requireSkillRouteReceipt(
                        args,
                        expectedTargets: expectedTargets,
                        toolName: "skills_exposure_reconcile"
                    )
                    let routeID = Self.exposureRouteID(args["routeReceipt"])
                    approvals = approvalRequests.map { request in
                        SkillExposureApproval(
                            id: request.approvalID ?? "\(routeID.lowercased())-\(SkillExposureIdentity.normalize(request.pageID))-\(request.requested.rawValue.lowercased())",
                            kind: .routeReceipt,
                            notionPageUUID: request.pageID,
                            previousExposure: request.previous,
                            requestedExposure: request.requested,
                            routeID: routeID,
                            authorizedAt: Date()
                        )
                    }
                } else if !approvalRequests.isEmpty {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skills_exposure_reconcile",
                        reason: "approvals are only accepted with mode='publish'"
                    )
                }

                guard let receipt = await SkillExposureReconciliationCoordinator.shared.run(
                    mode: mode,
                    approvals: approvals
                ) else {
                    return .object([
                        "outcome": .string("busy"),
                        "message": .string("A Runtime Exposure reconciliation is already running.")
                    ])
                }
                return Self.exposureReceiptValue(receipt)
            }
        ))

        await router.register(ToolRegistration(
            name: "skills_exposure_denylist",
            module: moduleName,
            tier: .notify,
            description: "List or change the emergency Runtime Exposure denylist. action='add' immediately reduces every surface for one Notion skill UUID. action='remove' restores only the active generation's already-published exposure. Mutations require a current SKILLS Keepr routeReceipt.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([.string("list"), .string("add"), .string("remove")])
                    ]),
                    "name": .object(["type": .string("string"), "description": .string("Governed skill name for add/remove route coverage.")]),
                    "pageId": .object(["type": .string("string"), "description": .string("Notion skill UUID for add/remove.")]),
                    "routeReceipt": SkillRouteReceiptValidator.schema
                ]),
                "required": .array([.string("action")])
            ]),
            handler: { arguments in
                let args = Self.unpackArgsObject(arguments)
                guard case .string(let action) = args["action"],
                      ["list", "add", "remove"].contains(action) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skills_exposure_denylist",
                        reason: "action must be list, add, or remove"
                    )
                }
                let store = SkillRuntimeGenerationStore.shared
                if action == "list" {
                    let ids = await store.emergencyDenylist().sorted()
                    return .object([
                        "action": .string("list"),
                        "pageIds": .array(ids.map(Value.string)),
                        "count": .int(ids.count)
                    ])
                }

                guard case .string(let rawName) = args["name"],
                      !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      case .string(let rawPageID) = args["pageId"],
                      SkillExposureIdentity.isValid(rawPageID) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skills_exposure_denylist",
                        reason: "add/remove requires a non-empty name and valid Notion pageId"
                    )
                }
                try Self.requireSkillRouteReceipt(
                    args,
                    expectedTargets: [rawName],
                    toolName: "skills_exposure_denylist"
                )
                let pageID = SkillExposureIdentity.normalize(rawPageID)
                var ids = await store.emergencyDenylist()
                let changed: Bool
                if action == "add" { changed = ids.insert(pageID).inserted }
                else { changed = ids.remove(pageID) != nil }
                await store.setEmergencyDenylist(ids)
                if let gate = await store.gate() {
                    await SkillRuntimeCachePruner.prune(using: gate)
                    await SkillRuntimeCachePruner.refreshRouting()
                }
                return .object([
                    "action": .string(action),
                    "name": .string(rawName),
                    "pageId": .string(CachedSkillBody.canonicalUUID(pageID)),
                    "changed": .bool(changed),
                    "pageIds": .array(ids.sorted().map(Value.string)),
                    "count": .int(ids.count)
                ])
            }
        ))

        await router.register(ToolRegistration(
            name: "skills_exposure_purge_orphans",
            module: moduleName,
            tier: .notify,
            description: "Drop named skill UUIDs from Bridge local + published Runtime Exposure registries after a SKILLS lifecycle decision. Default reconcile never auto-purges. pageIds must be explicit — there is no wildcard. outreach-dispatch (bcebfc86-3998-4bff-838e-97f15f8ec593) is HOLD and is refused. Does not approve exposure expansions and does not run publish reconcile. Requires a current SKILLS Keepr routeReceipt covering names.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageIds": .object([
                        "type": .string("array"),
                        "description": .string("Explicit Notion skill UUIDs to drop from local + published registries. Required. Empty/omitted is refused (no implicit sweep)."),
                        "items": .object(["type": .string("string")])
                    ]),
                    "names": .object([
                        "type": .string("array"),
                        "description": .string("Governed skill names matching pageIds, for routeReceipt.targetSkills coverage."),
                        "items": .object(["type": .string("string")])
                    ]),
                    "routeReceipt": SkillRouteReceiptValidator.schema
                ]),
                "required": .array([.string("pageIds"), .string("names")])
            ]),
            handler: { arguments in
                let args = Self.unpackArgsObject(arguments)
                let pageIds = try Self.parseNonEmptyStringArray(
                    args["pageIds"],
                    field: "pageIds",
                    toolName: "skills_exposure_purge_orphans"
                )
                let names = try Self.parseNonEmptyStringArray(
                    args["names"],
                    field: "names",
                    toolName: "skills_exposure_purge_orphans"
                )
                guard names.count == pageIds.count else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skills_exposure_purge_orphans",
                        reason: "names must have the same count as pageIds"
                    )
                }
                try Self.requireSkillRouteReceipt(
                    args,
                    expectedTargets: names,
                    toolName: "skills_exposure_purge_orphans"
                )
                let outcome = try await SkillExposureOrphanPurger.apply(
                    pageIDs: pageIds,
                    generationStore: .shared,
                    pruneCaches: true
                )
                return .object([
                    "purgedLocal": .array(outcome.purgedLocal.map(Value.string)),
                    "purgedPublished": .array(outcome.purgedPublished.map(Value.string)),
                    "held": .array(outcome.held.map(Value.string)),
                    "notFound": .array(outcome.notFound.map(Value.string)),
                    "invalid": .array(outcome.invalid.map(Value.string)),
                    "purgedLocalCount": .int(outcome.purgedLocal.count),
                    "purgedPublishedCount": .int(outcome.purgedPublished.count),
                    "heldCount": .int(outcome.held.count),
                    "holdPageIds": .array(SkillExposureOrphanPurge.holdPageIDs.sorted().map(Value.string))
                ])
            }
        ))
    }

    private static func parseNonEmptyStringArray(
        _ value: Value?,
        field: String,
        toolName: String
    ) throws -> [String] {
        guard case .array(let values)? = value, !values.isEmpty else {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "\(field) must be a non-empty array of strings"
            )
        }
        return try values.enumerated().map { index, item in
            guard case .string(let raw) = item else {
                throw ToolRouterError.invalidArguments(
                    toolName: toolName,
                    reason: "\(field)[\(index)] must be a string"
                )
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ToolRouterError.invalidArguments(
                    toolName: toolName,
                    reason: "\(field)[\(index)] must be a non-empty string"
                )
            }
            return trimmed
        }
    }

    private struct ExposureApprovalRequest {
        let name: String
        let pageID: String
        let previous: SkillRuntimeExposure?
        let requested: SkillRuntimeExposure
        let approvalID: String?
    }

    private static func parseExposureApprovalRequests(_ value: Value?) throws -> [ExposureApprovalRequest] {
        guard let value else { return [] }
        guard case .array(let values) = value else {
            throw ToolRouterError.invalidArguments(
                toolName: "skills_exposure_reconcile",
                reason: "approvals must be an array"
            )
        }
        return try values.enumerated().map { index, item in
            guard case .object(let fields) = item,
                  case .string(let rawName)? = fields["name"],
                  !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case .string(let pageID)? = fields["pageId"],
                  SkillExposureIdentity.isValid(pageID),
                  case .string(let rawRequested)? = fields["requestedExposure"],
                  let requested = SkillRuntimeExposure(rawValue: rawRequested) else {
                throw ToolRouterError.invalidArguments(
                    toolName: "skills_exposure_reconcile",
                    reason: "approvals[\(index)] requires name, valid pageId, and requestedExposure Off|Standard|Routing|Command"
                )
            }
            let previous: SkillRuntimeExposure?
            if case .string(let rawPrevious)? = fields["previousExposure"] {
                guard let parsed = SkillRuntimeExposure(rawValue: rawPrevious) else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "skills_exposure_reconcile",
                        reason: "approvals[\(index)].previousExposure must be Off|Standard|Routing|Command when supplied"
                    )
                }
                previous = parsed
            } else {
                previous = nil
            }
            let approvalID: String?
            if case .string(let raw)? = fields["approvalId"] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                approvalID = trimmed.isEmpty ? nil : trimmed
            } else {
                approvalID = nil
            }
            return .init(name: rawName, pageID: pageID, previous: previous,
                         requested: requested, approvalID: approvalID)
        }
    }

    private static func exposureRouteID(_ value: Value?) -> String {
        guard case .object(let fields)? = value,
              case .string(let routeID)? = fields["routeId"] else { return "R4" }
        return routeID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func exposureReceiptValue(_ receipt: SkillExposureReconciliationReceipt) -> Value {
        .object([
            "receiptId": .string(receipt.receiptID),
            "mode": .string(receipt.mode.rawValue),
            "outcome": .string(receipt.outcome.rawValue),
            "attemptedAt": .string(exposureISO8601(receipt.attemptedAt)),
            "snapshotId": receipt.snapshotID.map(Value.string) ?? .null,
            "candidateGenerationId": receipt.candidateGenerationID.map(Value.string) ?? .null,
            "activeGenerationId": receipt.activeGenerationID.map(Value.string) ?? .null,
            "errors": .array(receipt.errors.map(Value.string)),
            "warnings": .array(receipt.warnings.map(Value.string)),
            "changes": .array(receipt.changes.map(Value.string)),
            "errorCount": .int(receipt.errors.count),
            "warningCount": .int(receipt.warnings.count),
            "changeCount": .int(receipt.changes.count)
        ])
    }

    private static func exposureISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
