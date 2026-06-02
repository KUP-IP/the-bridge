// StandingOrdersModuleTests.swift — PKT-931 (v3.7·B)
// Covers StandingOrdersRecordStore + StandingOrdersModule: registration/tier,
// CRUD round-trip, idempotent upsert (no duplicate), soft-delete + archive,
// list archived exclusion / includeArchived opt-in, read 404 on soft-deleted,
// concurrent-save serialization (no last-write-wins race), and atomic-write
// persistence across a reload.

import Foundation
import MCP
import NotionBridgeLib

func runStandingOrdersModuleTests() async {
    print("\n\u{1F4DC} StandingOrdersModule Tests (PKT-931 · v3.7·B)")

    func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nb-so-\(UUID().uuidString).json")
    }

    func freshStore() -> StandingOrdersRecordStore {
        StandingOrdersRecordStore(storeURL: tmpURL())
    }

    // Pull the saved order id out of a standing_orders_save tool result.
    func savedID(_ result: Value) -> String? {
        guard case .object(let r) = result, case .object(let o)? = r["order"],
              case .string(let id)? = o["id"] else { return nil }
        return id
    }

    // ── registration / shape ──────────────────────────────────────────
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await StandingOrdersModule.register(on: router, store: freshStore())

    await test("StandingOrdersModule registers 4 tools under module=\"standing_orders\"") {
        let regs = await router.registrations(forModule: "standing_orders")
        let names = Set(regs.map(\.name))
        let expected: Set<String> = [
            "standing_orders_list", "standing_orders_read",
            "standing_orders_save", "standing_orders_delete"
        ]
        try expect(expected.isSubset(of: names), "missing — got \(names.sorted())")
        try expect(regs.count == 4, "expected 4, got \(regs.count)")
    }

    await test("all 4 standing_orders tools are tier .notify (writes must not auto-execute)") {
        let regs = await router.registrations(forModule: "standing_orders")
        for r in regs {
            try expect(r.tier == .notify, "\(r.name) must be .notify, got \(r.tier.rawValue)")
        }
    }

    await test("standing_orders_delete carries neverAutoApprove (destructive consent)") {
        let regs = await router.registrations(forModule: "standing_orders")
        let del = regs.first { $0.name == "standing_orders_delete" }
        try expect(del?.neverAutoApprove == true, "standing_orders_delete must require confirmation")
    }

    // ── store: CRUD round-trip ────────────────────────────────────────
    await test("store: create → read → list → update → delete round-trip") {
        let store = freshStore()
        let created = try await store.save(title: "Be terse", body: "Skip filler.", scope: .global)
        try expect(!created.id.isEmpty, "create should mint an id")

        let read = await store.read(id: created.id)
        try expect(read?.title == "Be terse", "read title mismatch")
        try expect(read?.body == "Skip filler.", "read body mismatch")
        try expect(read?.scope == .global, "read scope mismatch")

        let listed = await store.list()
        try expect(listed.count == 1, "expected 1 listed, got \(listed.count)")
        try expect(listed.first?.id == created.id, "listed id mismatch")

        let updated = try await store.save(id: created.id, title: "Be terse v2", body: "Skip all filler.", scope: .perSkill)
        try expect(updated.id == created.id, "update must keep the same id")
        try expect(updated.title == "Be terse v2", "update title not applied")
        try expect(updated.scope == .perSkill, "update scope not applied")

        let archived = try await store.delete(id: created.id)
        try expect(archived.archived, "delete should set archived=true")
        try expect(archived.archivedAt != nil, "delete should stamp archivedAt")
    }

    // ── store: idempotent upsert (no duplicate) ───────────────────────
    await test("store: save with same id is idempotent (no duplicate rows)") {
        let store = freshStore()
        let first = try await store.save(title: "Rule", body: "v1", scope: .global)
        _ = try await store.save(id: first.id, title: "Rule", body: "v2", scope: .global)
        _ = try await store.save(id: first.id, title: "Rule", body: "v3", scope: .global)
        let all = await store.list()
        try expect(all.count == 1, "expected 1 row after repeated upsert, got \(all.count)")
        let read = await store.read(id: first.id)
        try expect(read?.body == "v3", "last upsert body should win, got \(read?.body ?? "nil")")
    }

    // ── store: list metadata-only, no body leak ───────────────────────
    await test("store: list returns metadata only (no body field on summary)") {
        let store = freshStore()
        _ = try await store.save(title: "T", body: "SECRET-BODY", scope: .global)
        let summaries = await store.list()
        // StandingOrderSummary has no body property by type — assert the
        // metadata fields are present and well-formed instead.
        try expect(summaries.count == 1, "expected 1 summary")
        try expect(summaries.first?.title == "T", "summary title mismatch")
    }

    // ── store: soft-delete excluded from list by default, opt-in returns it ──
    await test("store: list excludes archived by default; includeArchived returns them") {
        let store = freshStore()
        let a = try await store.save(title: "Keep", body: "x", scope: .global)
        let b = try await store.save(title: "Drop", body: "y", scope: .global)
        _ = try await store.delete(id: b.id)

        let visible = await store.list()
        try expect(visible.count == 1, "expected 1 visible, got \(visible.count)")
        try expect(visible.first?.id == a.id, "visible should be the non-archived row")

        let withArchived = await store.list(includeArchived: true)
        try expect(withArchived.count == 2, "expected 2 with archived, got \(withArchived.count)")
    }

    // ── store: read of soft-deleted returns nil (→ 404) ───────────────
    await test("store: read of soft-deleted order returns nil (maps to 404)") {
        let store = freshStore()
        let o = try await store.save(title: "Gone", body: "z", scope: .global)
        _ = try await store.delete(id: o.id)
        let read = await store.read(id: o.id)
        try expect(read == nil, "soft-deleted read should be nil")
        let forced = await store.read(id: o.id, includeArchived: true)
        try expect(forced != nil, "includeArchived read should surface the archived row")
        try expect(forced?.archived == true, "forced read should still be archived")
    }

    // ── store: delete is idempotent + un-archive on re-save ───────────
    await test("store: delete is idempotent; re-save un-archives") {
        let store = freshStore()
        let o = try await store.save(title: "Toggle", body: "a", scope: .global)
        _ = try await store.delete(id: o.id)
        _ = try await store.delete(id: o.id)   // second delete: no-op success
        let stillOne = await store.list(includeArchived: true)
        try expect(stillOne.count == 1, "double-delete must not duplicate, got \(stillOne.count)")

        let revived = try await store.save(id: o.id, title: "Toggle", body: "b", scope: .global)
        try expect(!revived.archived, "re-save should un-archive")
        let visible = await store.list()
        try expect(visible.count == 1, "revived order should be visible again")
    }

    await test("store: delete of unknown id throws notFound") {
        let store = freshStore()
        do {
            _ = try await store.delete(id: "no-such-id")
            try expect(false, "expected notFound throw")
        } catch StandingOrdersRecordError.notFound {
            // expected
        }
    }

    // ── store: concurrent saves serialized by the actor (no race) ─────
    await test("store: concurrent saves serialized via actor (no last-write-wins race)") {
        let store = freshStore()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    _ = try? await store.save(title: "concurrent-\(i)", body: "b\(i)", scope: .global)
                }
            }
        }
        let all = await store.list()
        try expect(all.count == 50, "expected 50 distinct rows from concurrent saves, got \(all.count)")
    }

    // ── store: atomic persistence survives a reload from disk ─────────
    await test("store: saved orders persist atomically across a reload") {
        let url = tmpURL()
        let store = StandingOrdersRecordStore(storeURL: url)
        let o = try await store.save(title: "Persist", body: "durable", scope: .perTool)
        _ = try await store.delete(id: o.id)

        // Fresh store over the same URL = re-read the on-disk JSON.
        let reopened = StandingOrdersRecordStore(storeURL: url)
        let visible = await reopened.list()
        try expect(visible.isEmpty, "archived order should not be visible after reload")
        let archived = await reopened.list(includeArchived: true)
        try expect(archived.count == 1, "row should persist on disk (soft-delete, not purge)")
        try expect(archived.first?.scope == .perTool, "scope should survive the round-trip")
    }

    // ── tool layer: save → read → delete via MCP handlers ─────────────
    await test("tool: standing_orders_save then _read returns full body via handler") {
        let r = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await StandingOrdersModule.register(on: r, store: freshStore())

        let saveResult = try await r.dispatch(toolName: 
            "standing_orders_save",
            arguments: .object(["title": .string("Hello"), "body": .string("World body"), "scope": .string("per-context")])
        )
        guard let id = savedID(saveResult) else { try expect(false, "save did not return an id"); return }

        let readResult = try await r.dispatch(toolName: "standing_orders_read", arguments: .object(["id": .string(id)]))
        guard case .object(let rr) = readResult, case .object(let order)? = rr["order"],
              case .string(let body)? = order["body"], case .string(let scope)? = order["scope"] else {
            try expect(false, "read result missing order/body"); return
        }
        try expect(body == "World body", "read body mismatch: \(body)")
        try expect(scope == "per-context", "read scope mismatch: \(scope)")
    }

    await test("tool: standing_orders_read of unknown id returns not_found envelope") {
        let r = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await StandingOrdersModule.register(on: r, store: freshStore())
        let res = try await r.dispatch(toolName: "standing_orders_read", arguments: .object(["id": .string("nope")]))
        guard case .object(let o) = res, case .string(let code)? = o["error"] else {
            try expect(false, "expected error envelope"); return
        }
        try expect(code == "not_found", "expected not_found, got \(code)")
    }

    await test("tool: standing_orders_save rejects an invalid scope") {
        let r = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await StandingOrdersModule.register(on: r, store: freshStore())
        let res = try await r.dispatch(toolName: 
            "standing_orders_save",
            arguments: .object(["title": .string("X"), "body": .string("Y"), "scope": .string("bogus")])
        )
        guard case .object(let o) = res, case .string(let code)? = o["error"] else {
            try expect(false, "expected error envelope"); return
        }
        try expect(code == "invalid_scope", "expected invalid_scope, got \(code)")
    }
}
