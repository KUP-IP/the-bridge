// RoutingIntegrityLayerTests.swift - PKT-1094
// Server-owned tool/skill bindings, manifest-fetch dispatch gate, lifecycle
// scanners, and identity-propagation close contract.

import Foundation
import MCP
import TheBridgeLib

func runRoutingIntegrityLayerTests() async {
    print("\n\u{1F9ED} Routing Integrity Layer (PKT-1094)")

    func fakeMessagesSendRegistration() -> ToolRegistration {
        ToolRegistration(
            name: "messages_send",
            module: MessagesModule.moduleName,
            tier: .open,
            description: "Send an iMessage or SMS after explicit approval.",
            inputSchema: .object(["type": .string("object")]),
            handler: { arguments in
                if case .object(let object) = arguments,
                   object["_routingReceipt"] != nil || object["_routingReceipts"] != nil {
                    throw TestError.assertion("routing control metadata reached the tool handler")
                }
                return .object(["ok": .bool(true), "sent": .bool(true)])
            }
        )
    }

    await test("RIL registry: messages_send names governing skills") {
        guard let binding = ToolSkillBindingRegistry.binding(for: "messages_send") else {
            throw TestError.assertion("missing messages_send binding")
        }
        let slugs = Set(binding.governingSkills.map(\.slug))
        try expect(slugs.contains("people-keepr"), "people-keepr must govern message intent")
        try expect(slugs.contains("mac-message"), "mac-message must govern delivery mechanics")
        try expect(binding.requiresManifestFetch)
    }

    await test("RIL authority alias: mac-message canonicalizes to message without widening other authorities") {
        try expect(ToolSkillBindingRegistry.normalizeAuthoritySlug("mac-message") == "message")
        try expect(ToolSkillBindingRegistry.normalizeAuthoritySlug("message") == "message")
        try expect(ToolSkillBindingRegistry.normalizeAuthoritySlug("PEOPLE Keepr") == "people-keepr")

        let canonicalScopes = ToolSkillBindingRegistry.scopeIDs(governedBy: "message")
        let legacyScopes = ToolSkillBindingRegistry.scopeIDs(governedBy: "mac-message")
        try expect(canonicalScopes == legacyScopes,
                   "canonical message authority must inherit exactly the legacy mac-message scopes")
        try expect(canonicalScopes.contains("tool:messages_recent"),
                   "message authority must govern recent Messages reads")
        try expect(canonicalScopes.contains("tool:messages_send"),
                   "message authority must govern exact approved Messages sends")
    }

    await test("RIL discovery: messages_send tool description includes governance") {
        let rendered = MCPToolFactory.tool(for: fakeMessagesSendRegistration()).description ?? ""
        try expect(rendered.contains("Governance:"), "description must include governance annotation: \(rendered)")
        try expect(rendered.contains("people-keepr"), "description must name people-keepr: \(rendered)")
        try expect(rendered.contains("mac-message"), "description must name mac-message: \(rendered)")
        try expect(rendered.count <= BridgeToolDescriptionRenderer.charBudget,
                   "description budget breached: \(rendered.count)")
    }

    await test("RIL discovery: governed tool schemas centrally advertise receipt inputs") {
        guard case .object(let schema) = MCPToolFactory.inputSchema(for: fakeMessagesSendRegistration()),
              case .object(let properties)? = schema["properties"] else {
            throw TestError.assertion("governed schema is missing properties")
        }
        try expect(properties["_routingReceipt"] != nil, "single receipt input must be advertised")
        try expect(properties["_routingReceipts"] != nil, "composed receipt input must be advertised")
    }

    await test("RIL receipt: bridge_initialize carries registry snapshot") {
        try await withRILTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nseed")
            let receipt = BridgeInitializeService.buildReceipt(
                context: BridgeInitializeContext(
                    client: "ril-test",
                    connectionState: "local",
                    macToolsAvailable: true,
                    bridgeState: "running",
                    now: rilDate("2026-07-07")
                ),
                supplemental: [],
                telemetryEventRef: "evt-ril"
            )
            try expect(receipt.schemaVersion == 4, "receipt schema must include authoritative routing snapshot evidence")
            try expect(receipt.routingIntegrity.registryVersion == ToolSkillBindingRegistry.registryVersion)
            try expect(receipt.routingIntegrity.boundToolCount == ToolSkillBindingRegistry.bindings.count)
            try expect(receipt.routingIntegrity.manifestMarkerTools.contains(BridgeInitializeModule.toolName))
            try expect(receipt.routingIntegrity.manifestMarkerTools.contains("skills_routing_list"))
            try expect(!receipt.routingIntegrity.manifestMarkerTools.contains("list_routing_skills"),
                       "bridge_initialize must not advertise the removed routing alias")
            let value = BridgeInitializeModule.receiptValue(receipt)
            guard case .object(let dict) = value,
                  case .object(let ril)? = dict["routingIntegrity"],
                  case .int(let count)? = ril["boundToolCount"] else {
                throw TestError.assertion("receiptValue missing routingIntegrity.boundToolCount")
            }
            try expect(count == ToolSkillBindingRegistry.bindings.count)
        }
    }

    await test("RIL gate: fresh install reports bootstrap_required before any route acknowledgement") {
        try await withRILTempHome {
            let log = AuditLog()
            let router = ToolRouter(
                securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
                auditLog: log,
                routingCustodyStore: RoutingCustodyStore(
                    root: BridgePaths.applicationSupport(.routingCustody)
                ),
                licenseStatusProvider: { .trial(daysRemaining: 5) }
            )
            await MessagesModule.register(on: router)
            try await withNoDisabledTools {
                do {
                    _ = try await router.dispatch(
                        toolName: "messages_send",
                        arguments: .object([
                            "recipient": .string("+15555550123"),
                            "body": .string("dry-run probe"),
                            "confirm": .string("DRY_RUN")
                        ]),
                        context: ToolDispatchContext(transportSessionId: "ril-session-a", origin: .local)
                    )
                    throw TestError.assertion("messages_send reached handler without manifest marker")
                } catch let error as ToolRouterError {
                    if case .bootstrapRequired(let toolName, let reason) = error {
                        try expect(toolName == "messages_send")
                        try expect(reason.contains("no_verified_routing_snapshot"))
                    } else {
                        throw TestError.assertion("wrong ToolRouterError case: \(error)")
                    }
                }
            }
            let entries = await log.entries(forSessionID: "ril-session-a")
            try expect(entries.count == 1 && entries[0].approvalStatus == .rejected,
                       "bootstrap rejection must be audited exactly once")
        }
    }

    await test("RIL gate: only fetched governing skills authorize the current session") {
        try await withRILTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nseed")

            let log = AuditLog()
            let router = ToolRouter(
                securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
                auditLog: log,
                routingCustodyStore: RoutingCustodyStore(
                    root: BridgePaths.applicationSupport(.routingCustody)
                ),
                licenseStatusProvider: { .trial(daysRemaining: 5) }
            )
            await router.register(BridgeInitializeModule.makeTool(
                contextProvider: { client in
                    BridgeInitializeContext(
                        client: client,
                        connectionState: "local",
                        macToolsAvailable: true,
                        bridgeState: "running",
                        now: rilDate("2026-07-07")
                    )
                },
                preflightProvider: { CapabilityPreflightRegistry(probes: []) },
                routingSnapshotProvider: { _ in
                    SkillRoutingSnapshot(
                        metadata: .init(
                            status: .healthy,
                            source: .runtimeExposureGeneration,
                            snapshotID: "ril-session-test",
                            count: 3,
                            reason: "test"
                        ),
                        skills: (0..<3).map { .object(["name": .string("Routing \($0)")]) }
                    )
                }
            ))
            await registerRILFetchSkill(on: router)
            await MessagesModule.register(on: router)

            try await withNoDisabledTools {
                UserDefaults.standard.set(
                    ["messages_send": SecurityTier.open.rawValue],
                    forKey: BridgeDefaults.tierOverrides
                )
                _ = try await router.dispatch(
                    toolName: BridgeInitializeModule.toolName,
                    arguments: .object(["client": .string("ril-session-b")]),
                    context: ToolDispatchContext(transportSessionId: "ril-session-b", origin: .local)
                )
                let marked = await router.hasRoutingManifestMarker(sessionID: "ril-session-b")
                try expect(!marked, "bridge_initialize establishes readiness but must not authorize tools")

                let beforeFetch = await router.dispatchFormatted(
                    toolName: "messages_send",
                    arguments: .object([
                        "recipient": .string("+15555550123"),
                        "body": .string("dry-run probe"),
                        "confirm": .string("DRY_RUN")
                    ]),
                    context: ToolDispatchContext(transportSessionId: "ril-session-b", origin: .local)
                )
                try expect(beforeFetch.isError && beforeFetch.text.contains("route_ack_required"),
                           "initialization must not satisfy the governed route")

                _ = try await router.dispatch(
                    toolName: "fetch_skill",
                    arguments: .object(["name": .string("people-keepr")]),
                    context: ToolDispatchContext(transportSessionId: "ril-session-b", origin: .local)
                )
                _ = try await router.dispatch(
                    toolName: "fetch_skill",
                    arguments: .object(["name": .string("mac-message")]),
                    context: ToolDispatchContext(transportSessionId: "ril-session-b", origin: .local)
                )
                try expect(await router.hasRoutingManifestMarker(sessionID: "ril-session-b"),
                           "both fetched authorities must satisfy messages_send")

                let allowed = try await router.dispatch(
                    toolName: "messages_send",
                    arguments: .object([
                        "recipient": .string("+15555550123"),
                        "body": .string("dry-run probe"),
                        "confirm": .string("DRY_RUN")
                    ]),
                    context: ToolDispatchContext(transportSessionId: "ril-session-b", origin: .local)
                )
                guard case .object(let dict) = allowed,
                      case .bool(false)? = dict["sent"],
                      case .string(let error)? = dict["error"],
                      error.contains("confirm") else {
                    throw TestError.assertion("messages_send did not reach real no-send confirmation guard")
                }

                do {
                    _ = try await router.dispatch(
                        toolName: "messages_send",
                        arguments: .object([
                            "recipient": .string("+15555550123"),
                            "body": .string("dry-run probe"),
                            "confirm": .string("DRY_RUN")
                        ]),
                        context: ToolDispatchContext(transportSessionId: "ril-session-c", origin: .local)
                    )
                    throw TestError.assertion("marker leaked across sessions")
                } catch let error as ToolRouterError {
                    if case .routeAcknowledgementRequired(let tool, let scope, let governance) = error {
                        try expect(tool == "messages_send")
                        try expect(scope == "tool:messages_send")
                        try expect(governance.contains("people-keepr"))
                    }
                    else { throw TestError.assertion("wrong error for unmarked second session: \(error)") }
                }
            }

            let bTools = await log.entries(forSessionID: "ril-session-b").map(\.toolName)
            try expect(bTools == [
                BridgeInitializeModule.toolName,
                "messages_send",
                "fetch_skill",
                "fetch_skill",
                "messages_send"
            ],
                       "session b audit sequence drift: \(bTools)")
            let cEntries = await log.entries(forSessionID: "ril-session-c")
            try expect(cEntries.count == 1 && cEntries[0].approvalStatus == .rejected)
        }
    }

    await test("RIL restart: durable readiness survives replacement while client route acknowledgement does not") {
        try await withRILTempHome {
            let store = RoutingCustodyStore(root: BridgePaths.applicationSupport(.routingCustody))
            _ = try store.recordBootstrap(
                snapshotID: "restart-snapshot",
                source: "runtime_exposure_generation",
                count: 8,
                verifiedAt: rilDate("2026-07-07")
            )
            try store.recordPrincipalContinuation(
                principalKey: "oauth-sub:restart-user",
                authorityID: BridgeInitializeModule.toolName,
                at: rilDate("2026-07-07")
            )

            let routerBefore = ToolRouter(
                securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
                auditLog: AuditLog(),
                routingCustodyStore: store,
                licenseStatusProvider: { .trial(daysRemaining: 5) }
            )
            await registerRILRoutingList(on: routerBefore)
            await registerRILFetchSkill(on: routerBefore)
            await routerBefore.register(fakeMessagesSendRegistration())
            let context = ToolDispatchContext(
                transportSessionId: "restart-session",
                origin: .remote,
                client: "connector",
                governancePrincipal: "oauth-sub:restart-user"
            )
            _ = try await routerBefore.dispatch(toolName: "skills_routing_list", arguments: .object([:]), context: context)
            let beforeFetch = await routerBefore.dispatchFormatted(
                toolName: "messages_send", arguments: .object([:]), context: context
            )
            try expect(beforeFetch.isError && beforeFetch.text.contains("route_ack_required"),
                       "routing discovery must not authorize the tool")
            _ = try await routerBefore.dispatch(
                toolName: "fetch_skill", arguments: .object(["name": .string("people-keepr")]), context: context
            )
            _ = try await routerBefore.dispatch(
                toolName: "fetch_skill", arguments: .object(["name": .string("mac-message")]), context: context
            )
            _ = try await routerBefore.dispatch(toolName: "messages_send", arguments: .object([:]), context: context)

            // Simulates replacing/relaunching the app: same Application Support
            // state, fresh ToolRouter memory.
            let replacementStore = RoutingCustodyStore(root: BridgePaths.applicationSupport(.routingCustody))
            let routerAfter = ToolRouter(
                securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
                auditLog: AuditLog(),
                routingCustodyStore: replacementStore,
                licenseStatusProvider: { .trial(daysRemaining: 5) }
            )
            await registerRILRoutingList(on: routerAfter)
            await registerRILFetchSkill(on: routerAfter)
            await routerAfter.register(fakeMessagesSendRegistration())

            let rejected = await routerAfter.dispatchFormatted(
                toolName: "messages_send", arguments: .object([:]), context: context
            )
            try expect(rejected.isError && rejected.text.contains("route_ack_required"),
                       "replacement must retain bootstrap but demand a fresh client ack: \(rejected.text)")
            let roster = await routerAfter.dispatchFormatted(
                toolName: "skills_routing_list", arguments: .object([:]), context: context
            )
            try expect(!roster.isError)
            let afterRoster = await routerAfter.dispatchFormatted(
                toolName: "messages_send", arguments: .object([:]), context: context
            )
            try expect(afterRoster.isError && afterRoster.text.contains("route_ack_required"),
                       "routing discovery after replacement must not authorize the tool")
            _ = try await routerAfter.dispatch(
                toolName: "fetch_skill", arguments: .object(["name": .string("people-keepr")]), context: context
            )
            _ = try await routerAfter.dispatch(
                toolName: "fetch_skill", arguments: .object(["name": .string("mac-message")]), context: context
            )
            let allowed = await routerAfter.dispatchFormatted(
                toolName: "messages_send", arguments: .object([:]), context: context
            )
            try expect(!allowed.isError && allowed.text.contains("sent"))
        }
    }

    await test("RIL explicit receipt rejects every invalid class and consumes exactly once") {
        try await withRILTempHome {
            let store = RoutingCustodyStore(root: BridgePaths.applicationSupport(.routingCustody))
            let audit = AuditLog()
            let clock = RILRouteReceiptClock(Date(timeIntervalSince1970: 1_800_000_000))
            let router = ToolRouter(
                securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
                auditLog: audit,
                routingCustodyStore: store,
                routeReceiptNowProvider: { clock.now() },
                licenseStatusProvider: { .trial(daysRemaining: 5) }
            )
            await registerRILRoutingList(on: router)
            await registerRILFetchSkill(on: router)
            await router.register(fakeMessagesSendRegistration())
            let context = ToolDispatchContext(
                transportSessionId: ToolDispatchContext.remoteConnectorJSONSessionID,
                origin: .local,
                client: "compact-connector",
                governancePrincipal: "oauth-sub:receipt-user",
                routeAcknowledgementMode: .explicitReceipt
            )
            let roster = try await router.dispatch(
                toolName: "skills_routing_list", arguments: .object([:]), context: context
            )
            guard case .object(let rosterObject) = roster else {
                throw TestError.assertion("routing list fixture returned malformed output")
            }
            try expect(rosterObject["routingReceipts"] == nil,
                       "routing discovery must not issue authority receipts")

            let people = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("people-keepr")]),
                context: context
            )
            let mac = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("mac-message")]),
                context: context
            )
            func receipt(_ output: Value, scopeID: String) -> Value? {
                guard case .object(let object) = output,
                      case .array(let receipts)? = object["routingReceipts"] else { return nil }
                return receipts.first(where: {
                      guard case .object(let object) = $0,
                            case .string(scopeID)? = object["scopeID"] else { return false }
                      return true
                })
            }
            func replacing(_ value: Value, key: String, with replacement: Value) -> Value {
                guard case .object(var object) = value else { return value }
                object[key] = replacement
                return .object(object)
            }
            let compound = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("people-keepr/mac-message")]),
                context: context
            )
            guard let compoundReceipt = receipt(compound, scopeID: "tool:messages_send") else {
                throw TestError.assertion("compound fetch did not issue its parent authority receipt")
            }
            let compoundAttempt = await router.dispatchFormatted(
                toolName: "messages_send",
                arguments: .object(["_routingReceipt": compoundReceipt]),
                context: context
            )
            try expect(compoundAttempt.isError && compoundAttempt.text.contains("route_ack_required"),
                       "one compound fetch must not overgrant both authorities")

            let authoritativeID = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object([
                    "id": .string("0123456789abcdef0123456789abcdef"),
                    "name": .string("mac-message")
                ]),
                context: context
            )
            guard let authoritativeIDReceipt = receipt(authoritativeID, scopeID: "tool:messages_send"),
                  case .object(let authoritativeIDObject) = authoritativeIDReceipt,
                  case .array(let authoritativeIDValues)? = authoritativeIDObject["authorityIDs"] else {
                throw TestError.assertion("authoritative id fetch did not issue a receipt")
            }
            let authoritativeIDAuthorities: Set<String> = Set(authoritativeIDValues.compactMap {
                guard case .string(let value) = $0 else { return nil }
                return value
            })
            try expect(authoritativeIDAuthorities == Set(["people-keepr"]),
                       "an ignored name must not override id-derived authority: \(authoritativeIDAuthorities)")

            let conflictingIdentity = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["id": .string(String(repeating: "f", count: 32))]),
                context: context
            )
            guard case .object(let conflictingObject) = conflictingIdentity else {
                throw TestError.assertion("conflicting identity fixture returned malformed output")
            }
            try expect(conflictingObject["routingReceipts"] == nil,
                       "distinct registered slug/name identities must fail closed without a receipt")
            try expect(conflictingObject[ToolRouter.routingAuthorityEvidenceKey] == nil,
                       "internal authority evidence must never reach the caller")

            guard let peopleReceipt = receipt(people, scopeID: "tool:messages_send"),
                  let macReceipt = receipt(mac, scopeID: "tool:messages_send"),
                  let otherToolReceipt = receipt(people, scopeID: "tool:messages_recent") else {
                throw TestError.assertion("fetch_skill did not issue the required exact-scope receipts")
            }

            let withoutReceipt = await router.dispatchFormatted(
                toolName: "messages_send", arguments: .object([:]), context: context
            )
            try expect(withoutReceipt.isError && withoutReceipt.text.contains("route_ack_required"),
                       "stable compact alias must never become an implicit authority bucket")

            let malformed = await router.dispatchFormatted(
                toolName: "messages_send",
                arguments: .object(["_routingReceipt": .string("not-a-receipt")]),
                context: context
            )
            try expect(malformed.isError && malformed.text.contains("route_ack_required"))

            let wrongScope = await router.dispatchFormatted(
                toolName: "messages_send",
                arguments: .object(["_routingReceipt": otherToolReceipt]),
                context: context
            )
            try expect(wrongScope.isError && wrongScope.text.contains("route_ack_required"))

            let prematureReceipt = replacing(
                peopleReceipt,
                key: "issuedAt",
                with: .string("2099-01-01T00:00:00.000Z")
            )
            let premature = await router.dispatchFormatted(
                toolName: "messages_send",
                arguments: .object(["_routingReceipt": prematureReceipt]),
                context: context
            )
            try expect(premature.isError && premature.text.contains("route_ack_required"))

            let tamperedReceipt = replacing(
                peopleReceipt,
                key: "authorityIDs",
                with: .array([.string("people-keepr"), .string("mac-message")])
            )
            let tampered = await router.dispatchFormatted(
                toolName: "messages_send",
                arguments: .object(["_routingReceipt": tamperedReceipt]),
                context: context
            )
            try expect(tampered.isError && tampered.text.contains("route_ack_required"))

            let incomplete = await router.dispatchFormatted(
                toolName: "messages_send",
                arguments: .object(["_routingReceipt": peopleReceipt]),
                context: context
            )
            try expect(incomplete.isError && incomplete.text.contains("route_ack_required"),
                       "one governing skill must not satisfy a composed route")

            let args: Value = .object(["_routingReceipts": .array([peopleReceipt, macReceipt])])
            let wrongPrincipal = await router.dispatchFormatted(
                toolName: "messages_send",
                arguments: args,
                context: ToolDispatchContext(
                    transportSessionId: ToolDispatchContext.remoteConnectorJSONSessionID,
                    origin: .local,
                    client: "compact-connector",
                    governancePrincipal: "oauth-sub:other-user",
                    routeAcknowledgementMode: .explicitReceipt
                )
            )
            try expect(wrongPrincipal.isError && wrongPrincipal.text.contains("route_ack_required"))

            let first = await router.dispatchFormatted(toolName: "messages_send", arguments: args, context: context)
            try expect(!first.isError, "fresh receipt must authorize once: \(first.text)")
            let replay = await router.dispatchFormatted(toolName: "messages_send", arguments: args, context: context)
            try expect(replay.isError && replay.text.contains("route_ack_required"),
                       "receipt replay must fail closed: \(replay.text)")

            let expiringPeople = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("people-keepr")]),
                context: context
            )
            let expiringMac = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("mac-message")]),
                context: context
            )
            guard let expiringPeopleReceipt = receipt(expiringPeople, scopeID: "tool:messages_send"),
                  let expiringMacReceipt = receipt(expiringMac, scopeID: "tool:messages_send") else {
                throw TestError.assertion("fetch_skill did not issue expiring receipt fixtures")
            }
            clock.advance(by: 301)
            let expired = await router.dispatchFormatted(
                toolName: "messages_send",
                arguments: .object([
                    "_routingReceipts": .array([expiringPeopleReceipt, expiringMacReceipt])
                ]),
                context: context
            )
            try expect(expired.isError && expired.text.contains("route_ack_required"))

            let notes = await audit.entries(forSessionID: ToolDispatchContext.remoteConnectorJSONSessionID)
                .compactMap(\.governanceNote)
            for expected in [
                "route_receipt_rejected_missing",
                "route_receipt_rejected_malformed",
                "route_receipt_rejected_wrong_scope",
                "route_receipt_rejected_not_yet_valid",
                "route_receipt_rejected_tampered",
                "route_receipt_rejected_incomplete_authorities",
                "route_receipt_rejected_wrong_principal",
                "route_receipt_consumed",
                "route_receipt_rejected_replayed_or_unknown",
                "route_receipt_rejected_expired",
            ] {
                try expect(notes.contains(expected), "missing audit evidence for \(expected): \(notes)")
            }
        }
    }

    await test("RIL fetch_skill acknowledgements compose required authorities without leaking scopes") {
        try await withRILTempHome {
            let store = RoutingCustodyStore(root: BridgePaths.applicationSupport(.routingCustody))
            _ = try store.recordBootstrap(
                snapshotID: "scope-snapshot",
                source: "runtime_exposure_generation",
                count: 8,
                verifiedAt: rilDate("2026-07-07")
            )
            let router = ToolRouter(
                securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
                auditLog: AuditLog(),
                routingCustodyStore: store,
                licenseStatusProvider: { .trial(daysRemaining: 5) }
            )
            await router.register(ToolRegistration(
                name: "fetch_skill", module: "skills", tier: .open,
                description: "route authority fixture",
                inputSchema: .object(["type": .string("object")]),
                handler: { arguments in
                    guard case .object(let object) = arguments,
                          case .string(let name)? = object["name"] else { return .object(["error": .string("missing")]) }
                    return .object([
                        "title": .string(name),
                        "content": .string("fixture"),
                        ToolRouter.routingAuthorityEvidenceKey: .object(["name": .string(name)])
                    ])
                }
            ))
            await router.register(fakeMessagesSendRegistration())
            await router.register(ToolRegistration(
                name: "notion_page_create", module: "notion", tier: .open,
                description: "unrelated scope fixture", inputSchema: .object(["type": .string("object")]),
                handler: { _ in .object(["created": .bool(true)]) }
            ))
            let context = ToolDispatchContext(transportSessionId: "scope-session", origin: .local)
            _ = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("PEOPLE Keepr")]),
                context: context
            )
            let partial = await router.dispatchFormatted(
                toolName: "messages_send", arguments: .object([:]), context: context
            )
            try expect(partial.isError && partial.text.contains("route_ack_required"),
                       "people authority alone must not satisfy mac-message")
            _ = try await router.dispatch(
                toolName: "fetch_skill",
                arguments: .object(["name": .string("mac-message")]),
                context: context
            )
            let messages = await router.dispatchFormatted(
                toolName: "messages_send", arguments: .object([:]), context: context
            )
            try expect(!messages.isError)
            let notion = await router.dispatchFormatted(
                toolName: "notion_page_create", arguments: .object([:]), context: context
            )
            try expect(notion.isError && notion.text.contains("route_ack_required"),
                       "Messages route must not authorize Notion")
        }
    }

    await test("Amendment lifecycle: ACTIVE marker older than 30 days is due for collapse") {
        let md = """
        # Skill body
        - RIL-17 Amendment Status: ACTIVE since 2026-06-01
        - RIL-18 Amendment Status: ACTIVE since 2026-06-20
        - RIL-19 Amendment Status: SUPERSEDED since 2026-05-01
        """
        let due = AmendmentLifecycle.dueForCollapse(markdown: md, now: rilDate("2026-07-07"))
        try expect(due.map(\.identifier) == ["RIL-17"], "unexpected due markers: \(due.map(\.identifier))")
        try expect(due[0].ageDays >= 30)
    }

    await test("Identity propagation: unresolved impact hits block rename close") {
        let clean = IdentityPropagationScanResult(renameId: "rename-clean", unresolvedHits: 0, completedScanCycles: 1)
        try expect(IdentityPropagationContract.closeDecision(for: clean) == .canClose)

        let dirty = IdentityPropagationScanResult(renameId: "rename-dirty", unresolvedHits: 4, completedScanCycles: 1)
        try expect(IdentityPropagationContract.closeDecision(for: dirty) == .blockedByImpactHits)

        let repeated = IdentityPropagationScanResult(renameId: "rename-loop", unresolvedHits: 1, completedScanCycles: 3)
        try expect(IdentityPropagationContract.closeDecision(for: repeated) == .escalateAfterRepeatedHits)
    }
}

private func rilDate(_ yyyyMMdd: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: yyyyMMdd)!
}

private func withRILTempHome(_ body: () async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("RoutingIntegrityLayer-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body()
}

private func withNoDisabledTools(_ body: () async throws -> Void) async throws {
    let defaults = UserDefaults.standard
    let priorDisabled = defaults.object(forKey: BridgeDefaults.disabledTools)
    let priorToolOverrides = defaults.object(forKey: BridgeDefaults.tierOverrides)
    let priorModuleOverrides = defaults.object(forKey: BridgeDefaults.moduleTierOverrides)
    defaults.set([], forKey: BridgeDefaults.disabledTools)
    defaults.removeObject(forKey: BridgeDefaults.tierOverrides)
    defaults.removeObject(forKey: BridgeDefaults.moduleTierOverrides)
    defer {
        restore(defaults: defaults, key: BridgeDefaults.disabledTools, value: priorDisabled)
        restore(defaults: defaults, key: BridgeDefaults.tierOverrides, value: priorToolOverrides)
        restore(defaults: defaults, key: BridgeDefaults.moduleTierOverrides, value: priorModuleOverrides)
    }
    try await body()
}

private func restore(defaults: UserDefaults, key: String, value: Any?) {
    if let value {
        defaults.set(value, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
}

private func registerRILRoutingList(on router: ToolRouter) async {
    await router.register(ToolRegistration(
        name: "skills_routing_list",
        module: "skills",
        tier: .open,
        description: "healthy routing fixture",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in
            SkillRoutingSnapshot(
                metadata: .init(
                    status: .healthy,
                    source: .runtimeExposureGeneration,
                    snapshotID: "ril-routing-list",
                    count: 8,
                    reason: "test"
                ),
                skills: (0..<8).map { .object(["name": .string("Routing \($0)")]) }
            ).value
        }
    ))
}

private func registerRILFetchSkill(on router: ToolRouter) async {
    await router.register(ToolRegistration(
        name: "fetch_skill",
        module: "skills",
        tier: .open,
        description: "route authority fixture",
        inputSchema: .object(["type": .string("object")]),
        handler: { arguments in
            guard case .object(let object) = arguments else {
                return .object(["error": .string("missing name")])
            }
            if case .string(let id)? = object["id"] {
                return .object([
                    "slug": .string("people-keepr"),
                    "title": .string("mac-message"),
                    "content": .string("fixture"),
                    ToolRouter.routingAuthorityEvidenceKey: .object([
                        "slug": .string("people-keepr"),
                        "name": .string(id == String(repeating: "f", count: 32) ? "mac-message" : "people-keepr")
                    ])
                ])
            }
            guard case .string(let name)? = object["name"] else {
                return .object(["error": .string("missing name")])
            }
            let parent = String(name.split(separator: "/", maxSplits: 1).first ?? "")
            return .object([
                "slug": .string(name),
                "title": .string(name.contains("/") ? "mac-message" : name),
                "content": .string("fixture"),
                ToolRouter.routingAuthorityEvidenceKey: .object(["name": .string(parent)])
            ])
        }
    ))
}

private final class RILRouteReceiptClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}
