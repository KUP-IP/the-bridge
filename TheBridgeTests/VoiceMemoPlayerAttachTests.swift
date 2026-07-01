// VoiceMemoPlayerAttachTests.swift — PKT-1064 originating-Player relation
// TheBridge · Tests
//
// The memo → Memory curator must attach the ORIGINATING Player relation to the
// Memory row it creates (default = primary user player, Isaiah PLYR-5) AND
// verify it attached by read-back. When the Memory entity has no bound PLAYERS
// relation property, the write must BLOCK gracefully (throw → route to REVIEW),
// never a silent successful processed receipt, and never a crash.
//
// Hermetic: `executeMemoryKeep(entityKey:…entity:)` takes an injected entity
// binding, and stub `registry_create` / `registry_get` tools capture the write
// and serve the read-back — no live Notion.

import Foundation
import MCP
import TheBridgeLib

/// Captures the fields registry_create was called with, and holds the row the
/// stubbed registry_get should return for the verify read-back.
private actor MemoryKeepStubState {
    var createdFields: [String: Value] = [:]
    var createdEntity: String = ""
    /// Player ids the read-back reports as attached (empty = none).
    var readbackPlayerIds: [String] = []
    /// When true, the read-back envelope omits the players property entirely
    /// (simulates a create that silently dropped the relation).
    var omitPlayersOnReadback = false
    var createCallCount = 0
    var getCallCount = 0

    func recordCreate(entity: String, fields: [String: Value]) {
        createdEntity = entity
        createdFields = fields
        createCallCount += 1
    }

    func recordGet() { getCallCount += 1 }
    func setReadback(_ ids: [String]) { readbackPlayerIds = ids }
    func setOmitPlayers(_ omit: Bool) { omitPlayersOnReadback = omit }
}

private let kIsaiahPlayerId = "dc8e8f3f-e607-4b5d-809e-ae289574f40c"

/// Memory entity fixture WITH a bound PLAYERS relation property (`players`).
private func memoryEntityWithPlayers() -> RegistryEntity {
    RegistryEntity(
        key: "memory",
        displayName: "Memory",
        dataSourceId: "8a39359f-2246-40a2-8614-a487ba9abd23",
        properties: [
            RegistryProperty(key: "title", notionName: "Memory", notionPropertyId: "title", type: "title", role: .title),
            RegistryProperty(key: "summary", notionName: "Relevant:", notionPropertyId: "sum1", type: "rich_text"),
            RegistryProperty(key: "players", notionName: "PLAYERS", notionPropertyId: "rel1", type: "relation", role: .relation),
        ],
        cacheTTLSeconds: 3600,
        hasBody: true
    )
}

/// Memory entity fixture WITHOUT any PLAYERS relation (the current live binding).
private func memoryEntityNoPlayers() -> RegistryEntity {
    RegistryEntity(
        key: "memory",
        displayName: "Memory",
        dataSourceId: "8a39359f-2246-40a2-8614-a487ba9abd23",
        properties: [
            RegistryProperty(key: "title", notionName: "Memory", notionPropertyId: "title", type: "title", role: .title),
            RegistryProperty(key: "summary", notionName: "Relevant:", notionPropertyId: "sum1", type: "rich_text"),
            RegistryProperty(key: "url", notionName: "URL", notionPropertyId: "url1", type: "url"),
        ],
        cacheTTLSeconds: 3600,
        hasBody: true
    )
}

/// Memory entity fixture where PLAYERS is present but UNBOUND (no property id).
private func memoryEntityUnboundPlayers() -> RegistryEntity {
    RegistryEntity(
        key: "memory",
        displayName: "Memory",
        dataSourceId: "8a39359f-2246-40a2-8614-a487ba9abd23",
        properties: [
            RegistryProperty(key: "title", notionName: "Memory", notionPropertyId: "title", type: "title", role: .title),
            RegistryProperty(key: "players", notionName: "PLAYERS", notionPropertyId: nil, type: "relation", role: .relation),
        ],
        cacheTTLSeconds: 3600,
        hasBody: true
    )
}

/// Register stub registry_create / registry_get / notion_blocks_append on the
/// router (overwrites the real ones by name) driven by `state`. The read-back's
/// players relation is projected under the `players` canonical key.
private func installStubs(on router: ToolRouter, state: MemoryKeepStubState, pageId: String) async {
    let create = ToolRegistration(
        name: "registry_create", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { args in
            guard case .object(let a) = args,
                  case .string(let entity)? = a["entity"],
                  case .object(let fields)? = a["fields"] else {
                return .object(["created": .bool(false)])
            }
            await state.recordCreate(entity: entity, fields: fields)
            // Reflect whatever players value the caller wrote into the read-back,
            // so verify passes on a faithful attach and fails when it was dropped.
            if case .string(let p)? = fields["players"], !p.isEmpty {
                await state.setReadback([p])
            }
            return .object([
                "created": .bool(true),
                "row": .object([
                    "entity": .string(entity),
                    "id": .string(pageId),
                    "title": .string("Memo"),
                    "url": .string(""),
                    "properties": .object([:]),
                ]),
            ])
        })

    let get = ToolRegistration(
        name: "registry_get", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { args in
            await state.recordGet()
            let omit = await state.omitPlayersOnReadback
            let ids = await state.readbackPlayerIds
            var props: [String: Value] = ["title": .string("Memo")]
            if !omit {
                props["players"] = .array(ids.map { .string($0) })
            }
            return .object([
                "entity": .string("memory"),
                "id": .string(pageId),
                "properties": .object(props),
            ])
        })

    // Body append is irrelevant to attribution — accept and no-op.
    let append = ToolRegistration(
        name: "notion_blocks_append", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in .object(["ok": .bool(true)]) })

    await router.register(create)
    await router.register(get)
    await router.register(append)
}

private func memoryKeepIntent(fields: [String: String] = [:]) -> VoiceMemoIntent {
    VoiceMemoIntent(
        kind: .memoryKeep,
        confidence: 0.95,
        entityKey: "memory",
        title: "Preferred stack",
        fields: fields
    )
}

private func memoryKeepPlan() -> VoiceMemoPlan {
    VoiceMemoPlan(
        generatedTitle: "Preferred stack",
        skipMemoryKeep: false,
        summary: "Keep this: my preferred stack is Bridge plus Cursor.",
        actions: [],
        intents: []
    )
}

func runVoiceMemoPlayerAttachTests() async {
    print("\n\u{1F517} PKT-1064 — originating-Player relation attach + verify")

    // 1. Attaches the default originating player on memory_keep create.
    await test("PKT-1064: memory_keep attaches the originating Player relation at create") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = MemoryKeepStubState()
        await installStubs(on: router, state: state, pageId: "page-123")

        let detail = try await VoiceMemoProcessor.executeMemoryKeep(
            entityKey: "memory",
            intent: memoryKeepIntent(),
            plan: memoryKeepPlan(),
            transcript: "Keep this note.",
            router: router,
            entity: memoryEntityWithPlayers()
        )

        let fields = await state.createdFields
        try expect(fields["players"] == .string(kIsaiahPlayerId),
                   "create must carry players=\(kIsaiahPlayerId), got \(String(describing: fields["players"]))")
        try expect(detail.contains(kIsaiahPlayerId), "detail should record the attached player")
    }

    // 2. Verify read-back confirms the relation is present.
    await test("PKT-1064: verify read-back confirms the Player relation is present") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = MemoryKeepStubState()
        await installStubs(on: router, state: state, pageId: "page-verify")

        _ = try await VoiceMemoProcessor.executeMemoryKeep(
            entityKey: "memory",
            intent: memoryKeepIntent(),
            plan: memoryKeepPlan(),
            transcript: "Keep this note.",
            router: router,
            entity: memoryEntityWithPlayers()
        )

        let gets = await state.getCallCount
        try expect(gets >= 1, "a read-back registry_get must run to verify attachment")
    }

    // 3. Absent PLAYERS property → graceful BLOCKED (throws, no crash), and NO
    //    row is created (we block before the write).
    await test("PKT-1064: absent PLAYERS property blocks gracefully (throws, no crash)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = MemoryKeepStubState()
        await installStubs(on: router, state: state, pageId: "page-none")

        var threw = false
        do {
            _ = try await VoiceMemoProcessor.executeMemoryKeep(
                entityKey: "memory",
                intent: memoryKeepIntent(),
                plan: memoryKeepPlan(),
                transcript: "Keep this note.",
                router: router,
                entity: memoryEntityNoPlayers()
            )
        } catch let error as VoiceMemoError {
            threw = true
            if case .playerRelationUnbound = error {} else {
                try expect(false, "expected playerRelationUnbound, got \(error)")
            }
        }
        try expect(threw, "must throw when no bound PLAYERS relation exists")
        let creates = await state.createCallCount
        try expect(creates == 0, "must not create a Memory row when it cannot attribute a Player")
    }

    // 4. Present-but-UNBOUND PLAYERS property is treated as absent → BLOCKED.
    await test("PKT-1064: unbound PLAYERS property (no property id) also blocks gracefully") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = MemoryKeepStubState()
        await installStubs(on: router, state: state, pageId: "page-unbound")

        var threw = false
        do {
            _ = try await VoiceMemoProcessor.executeMemoryKeep(
                entityKey: "memory",
                intent: memoryKeepIntent(),
                plan: memoryKeepPlan(),
                transcript: "Keep this note.",
                router: router,
                entity: memoryEntityUnboundPlayers()
            )
        } catch let error as VoiceMemoError {
            threw = true
            if case .playerRelationUnbound = error {} else {
                try expect(false, "expected playerRelationUnbound, got \(error)")
            }
        }
        try expect(threw, "unbound PLAYERS must block like an absent one")
    }

    // 5. Read-back that omits the relation → verify failure (not a clean success).
    await test("PKT-1064: read-back missing the relation fails verification") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = MemoryKeepStubState()
        await installStubs(on: router, state: state, pageId: "page-drop")
        await state.setOmitPlayers(true)   // create "succeeds" but relation is gone

        var threw = false
        do {
            _ = try await VoiceMemoProcessor.executeMemoryKeep(
                entityKey: "memory",
                intent: memoryKeepIntent(),
                plan: memoryKeepPlan(),
                transcript: "Keep this note.",
                router: router,
                entity: memoryEntityWithPlayers()
            )
        } catch let error as VoiceMemoError {
            threw = true
            if case .playerRelationVerifyFailed = error {} else {
                try expect(false, "expected playerRelationVerifyFailed, got \(error)")
            }
        }
        try expect(threw, "a dropped relation on read-back must fail verification")
    }

    // 6. An explicit per-intent originating player overrides the default.
    await test("PKT-1064: explicit originatingPlayer override wins over the default") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = MemoryKeepStubState()
        await installStubs(on: router, state: state, pageId: "page-override")
        let other = "11111111-2222-3333-4444-555555555555"

        _ = try await VoiceMemoProcessor.executeMemoryKeep(
            entityKey: "memory",
            intent: memoryKeepIntent(fields: ["originatingPlayer": other]),
            plan: memoryKeepPlan(),
            transcript: "Keep this note.",
            router: router,
            entity: memoryEntityWithPlayers()
        )
        let fields = await state.createdFields
        try expect(fields["players"] == .string(other), "explicit override must be attached")
    }

    // 7. playersRelationKey matches the PLAYERS column case/space-insensitively
    //    and only when bound.
    await test("PKT-1064: playersRelationKey matches bound PLAYERS column, rename-safe") {
        try expect(VoiceMemoProcessor.playersRelationKey(in: memoryEntityWithPlayers()) == "players",
                   "should resolve the bound players relation key")
        try expect(VoiceMemoProcessor.playersRelationKey(in: memoryEntityNoPlayers()) == nil,
                   "no PLAYERS relation → nil")
        try expect(VoiceMemoProcessor.playersRelationKey(in: memoryEntityUnboundPlayers()) == nil,
                   "unbound PLAYERS → nil")
        try expect(VoiceMemoProcessor.playersRelationKey(in: nil) == nil, "nil entity → nil")
    }
}
