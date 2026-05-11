// LighthouseModule.swift — PKT-781 (Bridge v2.2 · 3.2a)
// Wraps Lighthouse via `npx --no-install lighthouse` under bg_process supervision.
// Tier: .request. Capability probe → capability_missing envelope when absent.
// Out of scope: typed JSON parsing (PKT-3.2b); W27 admin standard (PKT-3.2c).

import Foundation
import MCP

public enum LighthouseModule {
    public static let moduleName = "dev"
    public static let toolName   = "lighthouse_run"
    public static let runnerName = "lighthouse"

    public static func register(
        on router: ToolRouter,
        bgRuntime: BgProcessRuntime = BgProcessRuntime.shared,
        probeOverride: (@Sendable () async -> Bool)? = nil
    ) async {
        await router.register(ToolRegistration(
            name: toolName,
            module: moduleName,
            tier: .request,
            description: "Run Lighthouse via `npx --no-install lighthouse` under bg_process supervision. Probes capability first; returns `capability_missing` if Lighthouse is not installed (never installs). On success returns a bg_process jobId. Default args []; caller MUST supply target URL via `args` (e.g. ['https://example.com','--output=json','--output-path=/tmp/r.json','--chrome-flags=--headless=new']). No JSON parsing (PKT-3.2b scope).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "args": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Args to `npx lighthouse`. Default: []. Caller MUST include target URL.")
                    ]),
                    "cwd": .object(["type": .string("string"), "description": .string("Working directory (tilde-expanded).")]),
                    "env": .object(["type": .string("object"), "description": .string("Env vars merged on bridge env.")]),
                    "label": .object(["type": .string("string"), "description": .string("bg_process label (default 'lighthouse_run').")])
                ])
            ]),
            handler: { arguments in
                await RunnerToolImpl.handle(
                    toolName: toolName, runnerName: runnerName, defaultArgs: [],
                    arguments: arguments, bgRuntime: bgRuntime, probeOverride: probeOverride
                )
            }
        ))
    }
}
