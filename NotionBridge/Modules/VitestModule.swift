// VitestModule.swift — PKT-781 (Bridge v2.2 · 3.2a)
// Wraps Vitest via `npx --no-install vitest` under bg_process supervision.
// Tier: .request. Capability probe → capability_missing envelope when absent.
// Per Reflow #21 capability landscape vitest is NOT installed on this host —
// cap_missing path is the live-default state. Out of scope: typed JSON parsing
// (PKT-3.2b); live e2e (PKT-3.2c).

import Foundation
import MCP

public enum VitestModule {
    public static let moduleName = "dev"
    public static let toolName   = "vitest_run"
    public static let runnerName = "vitest"

    public static func register(
        on router: ToolRouter,
        bgRuntime: BgProcessRuntime = BgProcessRuntime.shared,
        probeOverride: (@Sendable () async -> Bool)? = nil
    ) async {
        await router.register(ToolRegistration(
            name: toolName,
            module: moduleName,
            tier: .request,
            description: "Run Vitest via `npx --no-install vitest` under bg_process supervision. Probes capability first; returns `capability_missing` if Vitest is not installed (never installs). On success returns a bg_process jobId. Default args ['run'] (one-shot non-watch); override via `args`. No JSON parsing (PKT-3.2b scope).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "args": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Args to `npx vitest`. Default: ['run'].")
                    ]),
                    "cwd": .object(["type": .string("string"), "description": .string("Working directory (tilde-expanded).")]),
                    "env": .object(["type": .string("object"), "description": .string("Env vars merged on bridge env.")]),
                    "label": .object(["type": .string("string"), "description": .string("bg_process label (default 'vitest_run').")])
                ])
            ]),
            handler: { arguments in
                await RunnerToolImpl.handle(
                    toolName: toolName, runnerName: runnerName, defaultArgs: ["run"],
                    arguments: arguments, bgRuntime: bgRuntime, probeOverride: probeOverride
                )
            }
        ))
    }
}
