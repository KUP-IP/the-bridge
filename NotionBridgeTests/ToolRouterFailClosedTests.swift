// ToolRouterFailClosedTests.swift — PKT-877 (Bridge v3.6·2)
// NotionBridgeTests
//
// THE SAFETY CONTRACT (W3): disabling a `ModuleGroup` must make EVERY
// tool in that group return a structured `BridgeToolError` at dispatch
// time. Silent failure (no audit row, generic ToolRouterError, or
// success-shaped response) is unacceptable.
//
// These tests assert the error TYPE — not just a return-value field —
// so a future refactor that swallows the gate into a string-shaped
// `(text, isError:true)` cannot accidentally satisfy the contract.

import Foundation
import MCP
import NotionBridgeLib

func runToolRouterFailClosedTests() async {
    print("\n\u{1F6A8} ToolRouter fail-closed (PKT-877 W3 · SAFETY CONTRACT)")

    /// Build a router with the live static registry. Stripe is excluded
    /// to avoid pulling the dynamic-proxy surface into a UI-state test.
    func buildRouter() async -> ToolRouter {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            includeStripe: false,
            registerSession: { r in await SessionModule.register(on: r, auditLog: log) }
        )
        return router
    }

    /// Persist `disabled` to UserDefaults so the router's gate check sees
    /// the same state the UI would have written. Restores prior state on
    /// scope exit via a defer in each test.
    func setDisabled(_ disabled: [String]) {
        UserDefaults.standard.set(disabled, forKey: BridgeDefaults.disabledTools)
    }
    func clearDisabled() {
        UserDefaults.standard.removeObject(forKey: BridgeDefaults.disabledTools)
    }

    // ----------------------------------------------------------------
    // 1) Disabled group → BridgeToolError (asserted by TYPE, not by text)
    // ----------------------------------------------------------------

    await test("disabling EVERY messages_* tool → messages_send throws BridgeToolError.moduleGroupDisabled") {
        defer { clearDisabled() }
        let router = await buildRouter()
        let allMessagesTools = await router.allRegistrations()
            .map(\.name)
            .filter { ModuleGroupDerivation.resolve(toolName: $0) == .messages }
        try expect(!allMessagesTools.isEmpty, "registry has no messages_* tools — registrar wiring drifted?")
        setDisabled(allMessagesTools)

        do {
            _ = try await router.dispatch(toolName: "messages_send", arguments: .object([:]))
            throw TestError.assertion("dispatch returned a value — fail-closed contract broken")
        } catch let err as BridgeToolError {
            switch err {
            case .moduleGroupDisabled(let toolName, let groupDisplayName):
                try expect(toolName == "messages_send")
                try expect(groupDisplayName == "messages")
            }
        } catch {
            throw TestError.assertion("dispatch threw the WRONG error type: \(type(of: error)) — \(error)")
        }
    }

    await test("disabling EVERY notion_* tool → notion_query throws BridgeToolError.moduleGroupDisabled") {
        defer { clearDisabled() }
        let router = await buildRouter()
        let allNotion = await router.allRegistrations()
            .map(\.name)
            .filter { ModuleGroupDerivation.resolve(toolName: $0) == .notion }
        setDisabled(allNotion)
        do {
            _ = try await router.dispatch(toolName: "notion_query", arguments: .object([:]))
            throw TestError.assertion("dispatch returned a value — fail-closed contract broken")
        } catch let err as BridgeToolError {
            if case .moduleGroupDisabled(let n, let g) = err {
                try expect(n == "notion_query")
                try expect(g == "notion")
            }
        } catch {
            throw TestError.assertion("wrong error type: \(type(of: error))")
        }
    }

    // ----------------------------------------------------------------
    // 2) Enabled group → normal dispatch (negative control)
    //    "Normal dispatch" here means the gate does NOT throw a
    //    BridgeToolError. The handler itself may still throw (the
    //    real notion_query needs a credential), but the type of error
    //    must NOT be BridgeToolError.moduleGroupDisabled.
    // ----------------------------------------------------------------

    await test("enabled group → gate does NOT throw BridgeToolError (allows real dispatch)") {
        defer { clearDisabled() }
        let router = await buildRouter()
        setDisabled([])  // nothing disabled
        do {
            // Pick a tool whose handler will likely succeed in CI: session_info.
            _ = try await router.dispatch(toolName: "session_info", arguments: .object([:]))
        } catch let err as BridgeToolError {
            throw TestError.assertion("BridgeToolError thrown for enabled group: \(err)")
        } catch {
            // Other errors (handler-shape failures, etc.) are fine — the
            // CONTRACT is only "gate does not block".
        }
    }

    // ----------------------------------------------------------------
    // 3) Re-enabling the group resumes dispatch (state-machine round-trip)
    // ----------------------------------------------------------------

    await test("partial disable: enabled siblings still dispatch, disabled members still gated... or not?") {
        defer { clearDisabled() }
        let router = await buildRouter()
        // Disable only ONE messages tool. The group is now "partial".
        // Per locked Q2 semantics, a partial group still has live members
        // the router MUST serve. Dispatching the still-enabled siblings
        // must NOT throw BridgeToolError. The single disabled member
        // would be blocked by the per-tool ListTools filter (existing
        // behaviour, not by the new group gate) — at dispatch time the
        // per-tool disable is intentionally NOT enforced by the router
        // gate because the existing pipeline returns Tool.ListTools-
        // filtered names; we only fail-closed at the ALL-OFF threshold.
        setDisabled(["messages_search"])

        // Sibling tool — still enabled in a partial group, gate must not block.
        do {
            _ = try await router.dispatch(toolName: "messages_chat", arguments: .object([:]))
        } catch let err as BridgeToolError {
            throw TestError.assertion("partial group blocked sibling: \(err)")
        } catch {
            // Any other error is acceptable for the gate contract.
        }
    }

    await test("round-trip: disable all → throws; re-enable → no longer throws") {
        defer { clearDisabled() }
        let router = await buildRouter()
        let allMessages = await router.allRegistrations()
            .map(\.name)
            .filter { ModuleGroupDerivation.resolve(toolName: $0) == .messages }

        // Phase 1: all disabled → must throw BridgeToolError.
        setDisabled(allMessages)
        var threwGated = false
        do {
            _ = try await router.dispatch(toolName: "messages_send", arguments: .object([:]))
        } catch let err as BridgeToolError {
            if case .moduleGroupDisabled = err { threwGated = true }
        } catch { /* other errors don't count */ }
        try expect(threwGated, "phase 1 — gated dispatch did not throw BridgeToolError")

        // Phase 2: re-enable → must NOT throw BridgeToolError.
        setDisabled([])
        do {
            _ = try await router.dispatch(toolName: "messages_send", arguments: .object([:]))
        } catch let err as BridgeToolError {
            throw TestError.assertion("phase 2 — group re-enabled but BridgeToolError still thrown: \(err)")
        } catch {
            // handler-shape errors are fine
        }
    }

    // ----------------------------------------------------------------
    // 4) dispatchFormatted bubbles the error to the (text, isError:true)
    //    surface — the wire-level guarantee the connector client sees.
    // ----------------------------------------------------------------

    await test("dispatchFormatted on a gated tool: isError == true AND text mentions the group") {
        defer { clearDisabled() }
        let router = await buildRouter()
        let allMessages = await router.allRegistrations()
            .map(\.name)
            .filter { ModuleGroupDerivation.resolve(toolName: $0) == .messages }
        setDisabled(allMessages)

        let result = await router.dispatchFormatted(toolName: "messages_send", arguments: .object([:]))
        try expect(result.isError == true, "gated dispatchFormatted did not set isError=true")
        try expect(result.text.contains("messages"), "gated error text does not name the group: \(result.text)")
        // Must also mention 'Settings → Tools' so the user knows where to fix it.
        try expect(result.text.contains("Settings") && result.text.contains("Tools"),
                   "gated error text does not point to Settings → Tools: \(result.text)")
    }
}
