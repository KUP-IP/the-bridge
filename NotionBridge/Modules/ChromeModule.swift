// ChromeModule.swift — Browser automation via Chrome Apple Events
// NotionBridge · Modules
//
// Provides Google Chrome automation through Apple Events using in-process
// NSAppleScript (same TCC-friendly pattern as AppleScriptModule).
//
// Tools:
//   chrome_tabs          (open)   — List all open tabs
//   chrome_navigate      (notify) — Navigate a tab to a URL or open new tab
//   chrome_read_page     (open)   — Extract page content via JavaScript
//   chrome_execute_js    (notify) — Execute arbitrary JavaScript in a tab
//   chrome_screenshot_tab(open)   — Capture visible tab content
//
// Created for FEATURE: ChromeModule — full browser automation via Apple Events.

import Foundation
import MCP
import ScreenCaptureKit

// MARK: - ChromeModule

/// Provides Google Chrome browser automation via Apple Events.
/// Uses in-process NSAppleScript to avoid TCC re-prompting.
public enum ChromeModule {

    public static let moduleName = "chrome"

    /// Register all ChromeModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: chrome_tabs_list – open  (Sprint A · mcp-builder #14 rename)
        let chromeTabsList = ToolRegistration(
            name: "chrome_tabs_list",
            module: moduleName,
            tier: .open,
            description: "List all open Chrome tabs across windows. Returns windowId + tabIndex for other chrome_* tools. Resilient to per-window/tab Apple Event failures; returns partialResults/errors when possible.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let visibleIDs = await visibleChromeWindowIDs()
                let script = """
                    tell application "Google Chrome"
                        set output to ""
                        set errorOutput to ""
                        repeat with w in windows
                            try
                                set winId to id of w
                                set tabIndex to 0
                                repeat with t in tabs of w
                                    set tabIndex to tabIndex + 1
                                    try
                                        set tabTitle to title of t
                                        set tabURL to URL of t
                                        set output to output & winId & "\t" & tabIndex & "\t" & tabTitle & "\t" & tabURL & linefeed
                                    on error errMsg number errNum
                                        set errorOutput to errorOutput & winId & "\t" & tabIndex & "\t" & errNum & "\t" & errMsg & linefeed
                                    end try
                                end repeat
                            on error errMsg number errNum
                                set errorOutput to errorOutput & "window" & "\t" & "0" & "\t" & errNum & "\t" & errMsg & linefeed
                            end try
                        end repeat
                        return output & "__NB_ERRORS__" & linefeed & errorOutput
                    end tell
                """

                let result = executeAppleScript(script)
                if let error = result.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(result.errorNumber ?? -1)
                    ])
                }

                // Parse tab-separated output into structured data. AppleScript emits a sentinel
                // before per-tab/window errors so one bad tab does not fail the full listing.
                let raw = result.value ?? ""
                let sections = raw.components(separatedBy: "__NB_ERRORS__\n")
                let lines = (sections.first ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
                let errorLines = (sections.count > 1 ? sections[1] : "").components(separatedBy: "\n").filter { !$0.isEmpty }
                var tabs: [Value] = []
                var errors: [Value] = []
                for line in lines {
                    let parts = line.components(separatedBy: "\t")
                    if parts.count >= 4 {
                        let isOnScreen = visibleIDs.contains(Int(parts[0]) ?? -1)
                        tabs.append(.object([
                            "windowId": .string(parts[0]),
                            "tabIndex": .string(parts[1]),
                            "title": .string(parts[2]),
                            "url": .string(parts[3]),
                            "onScreen": .bool(isOnScreen)
                        ]))
                    }
                }
                for line in errorLines {
                    let parts = line.components(separatedBy: "\t")
                    if parts.count >= 4 {
                        errors.append(.object([
                            "windowId": .string(parts[0]),
                            "tabIndex": .string(parts[1]),
                            "errorNumber": .string(parts[2]),
                            "error": .string(parts[3])
                        ]))
                    }
                }
                return .object([
                    "tabs": .array(tabs),
                    "count": .int(tabs.count),
                    "partialResults": .bool(!errors.isEmpty),
                    "errors": .array(errors)
                ])
            }
        )
        await router.register(chromeTabsList)
        // Sprint A · mcp-builder #14: one-cycle deprecation alias.
        await router.register(ToolDeprecationAlias.renameAlias(
            oldName: "chrome_tabs", newName: "chrome_tabs_list", from: chromeTabsList
        ))

        // MARK: chrome_navigate – notify
        await router.register(ToolRegistration(
            name: "chrome_navigate",
            module: moduleName,
            tier: .notify,
            description: "Navigate Chrome to a URL — new tab (newTab: true) or replace an existing tab's location. If Chrome is on another Space, returns an activation recovery hint or uses open fallback when untargeted.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The URL to navigate to")
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Optional window ID to target (from chrome_tabs)")
                    ]),
                    "tabIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Optional tab index within the window (from chrome_tabs)")
                    ]),
                    "newTab": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, open a new tab instead of navigating the current one (default: false)")
                    ])
                ]),
                "required": .array([.string("url")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let url) = args["url"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "chrome_navigate",
                        reason: "missing required 'url' parameter"
                    )
                }

                let newTab: Bool
                if case .bool(let val) = args["newTab"] {
                    newTab = val
                } else {
                    newTab = false
                }

                // Check if Chrome is visible on the current Space
                let chromeVisible = await visibleChromeWindowID() != nil

                let hasWindowTarget = args["windowId"] != nil || args["tabIndex"] != nil

                // If Chrome not visible and specific window/tab requested, return error
                if !chromeVisible && hasWindowTarget {
                    return .object([
                        "error": .string("Chrome is not visible on the current Space. Cannot target a specific window or tab."),
                        "navigated_via": .string("none"),
                        "recoveryHint": .string("Activate Chrome and bring a window onto the current Space, then rerun chrome_tabs and retry with an onScreen windowId/tabIndex. AppleScript fallback: tell application \"Google Chrome\" to activate")
                    ])
                }

                // If Chrome not visible, fall back to macOS `open` command
                if !chromeVisible {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = [url]
                    do {
                        try process.run()
                        process.waitUntilExit()
                    } catch {
                        return .object([
                            "error": .string("Failed to open URL via fallback: \(error.localizedDescription)"),
                            "navigated_via": .string("open_fallback")
                        ])
                    }
                    guard process.terminationStatus == 0 else {
                        return .object([
                            "error": .string("open command exited with status \(process.terminationStatus)"),
                            "navigated_via": .string("open_fallback")
                        ])
                    }
                    return .object([
                        "result": .string("ok"),
                        "navigatedTo": .string(url),
                        "navigated_via": .string("open_fallback"),
                        "newTab": .bool(newTab)
                    ])
                }

                // Chrome IS visible on current Space — use existing AppleScript navigation
                let escapedURL = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

                let script: String
                if newTab {
                    script = """
                        tell application "Google Chrome"
                            tell front window
                                make new tab with properties {URL:"\(escapedURL)"}
                            end tell
                            return "ok"
                        end tell
                    """
                } else if let windowIdVal = args["windowId"],
                          let tabIndexVal = args["tabIndex"],
                          case .int(let windowId) = windowIdVal,
                          case .int(let tabIndex) = tabIndexVal {
                    script = """
                        tell application "Google Chrome"
                            repeat with w in windows
                                if id of w is \(windowId) then
                                    set URL of tab \(tabIndex) of w to "\(escapedURL)"
                                    return "ok"
                                end if
                            end repeat
                            return "window not found"
                        end tell
                    """
                } else {
                    script = """
                        tell application "Google Chrome"
                            set URL of active tab of front window to "\(escapedURL)"
                            return "ok"
                        end tell
                    """
                }

                let result = executeAppleScript(script)
                if let error = result.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(result.errorNumber ?? -1),
                        "navigated_via": .string("applescript"),
                        "recoveryHint": .string("If this is a tab-index churn error, rerun chrome_tabs immediately and retry with the refreshed windowId/tabIndex. If Chrome is off-screen, activate it first: tell application \"Google Chrome\" to activate")
                    ])
                }
                return .object([
                    "result": .string(result.value ?? "ok"),
                    "navigatedTo": .string(url),
                    "navigated_via": .string("applescript")
                ])
            }
        ))

        // MARK: chrome_read_page – open
        await router.register(ToolRegistration(
            name: "chrome_read_page",
            module: moduleName,
            tier: .open,
            description: "Extract readable content from a Chrome tab (innerText or innerHTML), optionally scoped by CSS selector. Read-only — use chrome_execute_js to mutate.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "selector": .object([
                        "type": .string("string"),
                        "description": .string("Optional CSS selector to target a specific element (default: document.body)")
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "description": .string("'text' for innerText (default) or 'html' for innerHTML")
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Optional window ID (from chrome_tabs)")
                    ]),
                    "tabIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Optional tab index (from chrome_tabs)")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value]
                if case .object(let a) = arguments {
                    args = a
                } else {
                    args = [:]
                }

                let selector: String
                if case .string(let s) = args["selector"] {
                    selector = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                } else {
                    selector = ""
                }

                let useHTML: Bool
                if case .string(let m) = args["mode"], m == "html" {
                    useHTML = true
                } else {
                    useHTML = false
                }

                let prop = useHTML ? "innerHTML" : "innerText"
                let jsElement = selector.isEmpty
                    ? "document.body"
                    : "document.querySelector('\(selector)')"
                let js = "(\(jsElement) || {}).\(prop) || ''"

                let escapedJS = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

                let tabTarget: String
                if let windowIdVal = args["windowId"],
                   let tabIndexVal = args["tabIndex"],
                   case .int(let windowId) = windowIdVal,
                   case .int(let tabIndex) = tabIndexVal {
                    tabTarget = "tell tab \(tabIndex) of (first window whose id is \(windowId))"
                } else {
                    tabTarget = "tell active tab of front window"
                }

                let script = """
                    tell application "Google Chrome"
                        \(tabTarget)
                            set pageContent to execute javascript "\(escapedJS)"
                        end tell
                        return pageContent
                    end tell
                """

                let result = executeAppleScript(script)
                if let error = result.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(result.errorNumber ?? -1)
                    ])
                }

                let content = result.value ?? ""
                return .object([
                    "content": .string(content),
                    "length": .int(content.count),
                    "mode": .string(useHTML ? "html" : "text")
                ])
            }
        ))

        // MARK: chrome_execute_js – notify
        await router.register(ToolRegistration(
            name: "chrome_execute_js",
            module: moduleName,
            tier: .notify,
            description: "Execute arbitrary JavaScript in a Chrome tab (DOM mutation, form fill, click). For pure reads prefer chrome_read_page.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "javascript": .object([
                        "type": .string("string"),
                        "description": .string("The JavaScript code to execute in the tab")
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Optional window ID (from chrome_tabs)")
                    ]),
                    "tabIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Optional tab index (from chrome_tabs)")
                    ])
                ]),
                "required": .array([.string("javascript")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let javascript) = args["javascript"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "chrome_execute_js",
                        reason: "missing required 'javascript' parameter"
                    )
                }

                let escapedJS = javascript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

                let tabTarget: String
                if let windowIdVal = args["windowId"],
                   let tabIndexVal = args["tabIndex"],
                   case .int(let windowId) = windowIdVal,
                   case .int(let tabIndex) = tabIndexVal {
                    tabTarget = "tell tab \(tabIndex) of (first window whose id is \(windowId))"
                } else {
                    tabTarget = "tell active tab of front window"
                }

                let script = """
                    tell application "Google Chrome"
                        \(tabTarget)
                            set jsResult to execute javascript "\(escapedJS)"
                        end tell
                        return jsResult
                    end tell
                """

                let result = executeAppleScript(script)
                if let error = result.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(result.errorNumber ?? -1)
                    ])
                }
                let resultValue = result.value ?? ""
                let isVoid = result.value == nil
                return .object([
                    "result": .string(resultValue),
                    "resultType": .string(isVoid ? "void" : "string")
                ])
            }
        ))

        // MARK: chrome_screenshot_tab – open
        await router.register(ToolRegistration(
            name: "chrome_screenshot_tab",
            module: moduleName,
            tier: .open,
            description: "DEPRECATED — use `screen_capture` with target={kind:'chrome_tab', windowId, tabIndex} (audit-recommended 2-cycle; operator Q4=a override to 1-cycle). Removed in 3.5.0. Screenshot a specific Chrome tab's rendered viewport as PNG.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Optional window ID (from chrome_tabs)")
                    ]),
                    "tabIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Optional tab index (from chrome_tabs)")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value]
                if case .object(let a) = arguments {
                    args = a
                } else {
                    args = [:]
                }

                let targetBoundsExpression: String
                if let windowIdVal = args["windowId"],
                   let tabIndexVal = args["tabIndex"],
                   case .int(let windowId) = windowIdVal,
                   case .int(let tabIndex) = tabIndexVal {
                    let activateTabScript = """
                        tell application "Google Chrome"
                            set active tab index of (first window whose id is \(windowId)) to \(tabIndex)
                            return "ok"
                        end tell
                    """
                    let activateTabResult = executeAppleScript(activateTabScript)
                    if let error = activateTabResult.error {
                        return .object([
                            "error": .string(error),
                            "errorNumber": .int(activateTabResult.errorNumber ?? -1)
                        ])
                    }
                    targetBoundsExpression = "bounds of (first window whose id is \(windowId))"
                } else {
                    targetBoundsExpression = "bounds of front window"
                }

                let boundsScript = """
                    tell application "Google Chrome"
                        set b to \(targetBoundsExpression)
                        return (item 1 of b as string) & "," & (item 2 of b as string) & "," & (item 3 of b as string) & "," & (item 4 of b as string)
                    end tell
                """
                let boundsResult = executeAppleScript(boundsScript)
                if let error = boundsResult.error {
                    return .object([
                        "error": .string(error),
                        "errorNumber": .int(boundsResult.errorNumber ?? -1)
                    ])
                }

                let boundsParts = (boundsResult.value ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard boundsParts.count == 4,
                      let x1 = Int(boundsParts[0]),
                      let y1 = Int(boundsParts[1]),
                      let x2 = Int(boundsParts[2]),
                      let y2 = Int(boundsParts[3]) else {
                    return .object([
                        "error": .string("Failed to parse Chrome window bounds")
                    ])
                }

                let width = x2 - x1
                let height = y2 - y1
                guard width > 0, height > 0 else {
                    return .object([
                        "error": .string("Invalid Chrome window bounds")
                    ])
                }

                _ = executeAppleScript("tell application \"Google Chrome\" to activate")
                try await Task.sleep(nanoseconds: 300_000_000)

                let tempDir = FileManager.default.temporaryDirectory
                let filename = "chrome_screenshot_\(Int(Date().timeIntervalSince1970)).png"
                let filePath = tempDir.appendingPathComponent(filename).path

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-R", "\(x1),\(y1),\(width),\(height)", "-x", filePath]

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    return .object([
                        "error": .string("Failed to run screencapture: \(error.localizedDescription)")
                    ])
                }

                guard process.terminationStatus == 0 else {
                    return .object([
                        "error": .string("screencapture exited with status \(process.terminationStatus)")
                    ])
                }

                let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
                let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0

                return .object([
                    "path": .string(filePath),
                    "width": .int(width),
                    "height": .int(height),
                    "size": .int(fileSize)
                ])
            }
        ))
    }

    // MARK: - Internal helpers

    private struct AppleScriptResult {
        let value: String?
        let error: String?
        let errorNumber: Int?
    }

    private static func executeAppleScript(_ source: String) -> AppleScriptResult {
        let appleScript = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? -1
            return AppleScriptResult(value: nil, error: errorMessage, errorNumber: errorNumber)
        }

        return AppleScriptResult(value: result?.stringValue, error: nil, errorNumber: nil)
    }

    /// Returns the window ID of the first on-screen Chrome window, or nil if none visible on current Space.
    private static func visibleChromeWindowID() async -> Int? {
        // Fast short-circuit when Screen Recording is denied — never enter SCK.
        guard CGPreflightScreenCaptureAccess() else { return nil }
        // SCK delivers its reply on the main run loop; an off-main call leaks
        // the continuation and hangs. Route through the main-actor boundary.
        guard let content = try? await SCKBoundary.fetchShareableContent() else {
            return nil
        }
        let chromeWindow = content.windows.first {
            $0.owningApplication?.bundleIdentifier == "com.google.Chrome"
        }
        guard let window = chromeWindow else { return nil }
        return Int(window.windowID)
    }

    /// Returns the set of all on-screen Chrome window IDs on the current Space.
    private static func visibleChromeWindowIDs() async -> Set<Int> {
        // Fast short-circuit when Screen Recording is denied — never enter SCK.
        guard CGPreflightScreenCaptureAccess() else { return [] }
        // SCK delivers its reply on the main run loop; an off-main call leaks
        // the continuation and hangs. Route through the main-actor boundary.
        guard let content = try? await SCKBoundary.fetchShareableContent() else {
            return []
        }
        let ids = content.windows
            .filter { $0.owningApplication?.bundleIdentifier == "com.google.Chrome" }
            .map { Int($0.windowID) }
        return Set(ids)
    }

}
