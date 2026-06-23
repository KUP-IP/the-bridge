import Foundation
import MCP
import TheBridgeLib

func runConnectionsModuleTests() async {
    print("\n🔌 ConnectionsModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await ConnectionsModule.register(on: router)

    await test("ConnectionsModule registers 5 tools") {
        let tools = await router.registrations(forModule: "connections")
        try expect(tools.count == 5, "Expected 5 connections tools, got \(tools.count)")
    }

    let expectedTools = [
        "connections_list",
        "connections_get",
        "connections_health",
        "connections_validate",
        "connections_capabilities"
    ]

    for toolName in expectedTools {
        await test("Tool \(toolName) is registered") {
            let tools = await router.registrations(forModule: "connections")
            try expect(tools.contains(where: { $0.name == toolName }), "Missing \(toolName)")
        }
    }

    for toolName in expectedTools {
        await test("\(toolName) tier is open") {
            let tools = await router.registrations(forModule: "connections")
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                throw TestError.assertion("Tool \(toolName) not found")
            }
            try expect(tool.tier == .open, "Expected open tier for \(toolName)")
        }
    }

    await test("connections_get rejects missing connectionId") {
        do {
            _ = try await router.dispatch(
                toolName: "connections_get",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing connectionId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("connections_validate rejects missing connectionId") {
        do {
            _ = try await router.dispatch(
                toolName: "connections_validate",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing connectionId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("connections_capabilities rejects missing connectionId") {
        do {
            _ = try await router.dispatch(
                toolName: "connections_capabilities",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing connectionId")
        } catch is ToolRouterError {
            // Expected
        }
    }
}
