// AppleScriptModule.swift – In-process AppleScript execution
// TheBridge · Modules
//
// Solves TCC permission re-prompting by executing AppleScript via NSAppleScript
// instead of shelling out to /usr/bin/osascript. When NSAppleScript runs in-process,
// macOS grants Automation TCC to TheBridge.app itself — one grant, permanent.
//
// Created by PKT-356 hotfix: TCC prompt storm on osascript child processes.
// V1-03 (BUG-FIX): Added TCC error detection (-1743) with actionable guidance.

import Foundation
import MCP

// MARK: - AppleScriptModule

/// Provides in-process AppleScript execution to avoid TCC re-prompting.
/// Use this instead of `shell_exec` + `osascript` for any Apple Event automation
/// (controlling Chrome, System Events, Finder, etc.).
public enum AppleScriptModule {

    public static let moduleName = "applescript"

    /// Register all AppleScriptModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: applescript_exec – request
        await router.register(ToolRegistration(
            name: "applescript_exec",
            module: moduleName,
            tier: .request,
            description: "Run AppleScript in-process under The Bridge's TCC grants. Preferred over shell_exec osascript. Priority 2 on the app-control cascade (after Accessibility).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "script": .object([
                        "type": .string("string"),
                        "description": .string("The AppleScript source code to execute")
                    ])
                ]),
                "required": .array([.string("script")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let script) = args["script"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "applescript_exec",
                        reason: "missing required 'script' parameter"
                    )
                }

                let appleScript = NSAppleScript(source: script)
                var errorInfo: NSDictionary?
                let result = appleScript?.executeAndReturnError(&errorInfo)

                if let error = errorInfo {
                    let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? -1

                    // V1-03: Detect TCC Automation denial (error -1743) and provide
                    // actionable guidance. This error means The Bridge does not have
                    // Automation permission for the target application.
                    if errorNumber == -1743 {
                        // Attempt to extract the target app name from the script
                        let targetApp = extractTargetApp(from: script) ?? "the target application"
                        return .object([
                            "error": .string(errorMessage),
                            "errorNumber": .int(errorNumber),
                            "tccDenied": .bool(true),
                            "guidance": .string(
                                "The Bridge does not have Automation permission for \(targetApp). "
                                + "This is a macOS TCC (Transparency, Consent, and Control) restriction. "
                                + "To fix: Open The Bridge's permission panel — the periodic permission "
                                + "check will probe \(targetApp) and trigger the macOS consent prompt. "
                                + "Alternatively, open System Settings > Privacy & Security > Automation "
                                + "and grant The Bridge access to \(targetApp)."
                            )
                        ])
                    }

                    return .object([
                        "error": .string(errorMessage),
                        "errorNumber": .int(errorNumber)
                    ])
                }

                let resultString = result?.stringValue ?? ""
                return .object([
                    "result": .string(resultString)
                ])
            }
        ))
    }

    // MARK: - Helpers

    /// Extract the target application name from a `tell application "X"` script.
    /// Returns nil if no target is found.
    private static func extractTargetApp(from script: String) -> String? {
        // Match: tell application "AppName"
        let pattern = #"tell application \"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: script,
                range: NSRange(script.startIndex..., in: script)
              ),
              let range = Range(match.range(at: 1), in: script) else {
            return nil
        }
        return String(script[range])
    }
}
