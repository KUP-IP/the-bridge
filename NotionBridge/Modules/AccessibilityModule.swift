// AccessibilityModule.swift
// NotionBridge · Modules
//
// Native Mac UI steering via ApplicationServices framework.
// Tools (post-Sprint A · mcp-builder Phase 2):
//   - ax_inspect       (open)   ← discriminated-union AX query (rename of ax_query)
//   - ax_query         (open)   ← one-cycle deprecation alias for ax_inspect (removed in 3.5.0)
//   - ax_focused_app   (open)   ← REVIVED as new dedicated zero-arg top-level tool (Sprint A · #11)
//   - ax_tree          (open)
//   - ax_perform_action (notify)
//
// PKT-356: original Mac Steering Sprint scaffold.
// PKT-755 (Bridge v2.2 · 0.1.2): consolidated three overlapping AX query
//   tools (ax_focused_app + ax_find_element + ax_element_info) into a single
//   ax_query with a discriminated-union schema. The originals shipped as
//   deprecation shims; both the new tool and the shims dispatched through
//   the same private *Payload(...) helpers (with an injected `_deprecated`
//   marker on the shims).
// Sprint A (mcp-builder Phase 2):
//   #1   removed the v2.2 deprecation shims (cycle complete).
//   #11  renamed ax_query → ax_inspect (one-cycle alias on the old name)
//        AND revived ax_focused_app as a NEW dedicated zero-arg top-level
//        tool — NOT a deprecation shim. The revival has its own annotation
//        entry and a test that pins the absence of any DEPRECATED prefix.
// The legacy `deprecationWarning` constant + `_deprecated` marker code
// path remain reachable from `ax_query` (the alias) and continue to inject
// the prior marker shape into responses for one cycle. Dead-stripped in 3.5.0.

import MCP
import AppKit

public enum AccessibilityModule {

    public static let moduleName = "accessibility"

    // PKT-755: marker injected into responses from the three collapsed tools.
    // Removed entirely with the shims in v2.3.
    private static let deprecationWarning =
        "Tool deprecated in v2.2 (PKT-755). Prefer ax_query with mode='focused_app' / 'find_element' / 'element_info'. This tool will be removed in v2.3."

    // MARK: - Errors

    private enum AXModuleError: Error {
        case notTrusted
        case noFocusedApp
        case appNotFound(pid: Int32)
        case elementNotFound(query: String)
        case actionFailed(action: String, detail: String)
        case invalidInput(String)

        func toResponse() -> Value {
            let msg: String
            switch self {
            case .notTrusted:
                msg = "Accessibility permission not granted. Enable in System Settings > Privacy & Security > Accessibility."
            case .noFocusedApp:
                msg = "No focused application found."
            case .appNotFound(let pid):
                msg = "Application with PID \(pid) not found or not running."
            case .elementNotFound(let query):
                msg = "Element not found matching: \(query)"
            case .actionFailed(let action, let detail):
                msg = "Action '\(action)' failed: \(detail)"
            case .invalidInput(let detail):
                msg = "Invalid input: \(detail)"
            }
            return .object(["error": .string(msg)])
        }
    }

    // MARK: - AX Helpers

    private static func ensureTrusted() throws {
        guard AXIsProcessTrusted() else { throw AXModuleError.notTrusted }
    }

    private static func focusedApp() throws -> (AXUIElement, NSRunningApplication) {
        try ensureTrusted()
        let sys = AXUIElementCreateSystemWide()
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &ref) == .success,
              let appEl = ref as! AXUIElement? else { // Safe: CF bridging guarantees type on .success
            throw AXModuleError.noFocusedApp
        }
        var pid: pid_t = 0
        AXUIElementGetPid(appEl, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw AXModuleError.appNotFound(pid: pid)
        }
        return (appEl, app)
    }

    // MARK: - Parameter Helpers

    private static func resolvePid(_ params: [String: Value]) throws -> pid_t {
        if let p = params["pid"] {
            switch p {
            case .int(let v):    return pid_t(v)
            case .double(let v): return pid_t(v)
            default: throw AXModuleError.invalidInput("pid must be an integer")
            }
        }
        let (_, app) = try focusedApp()
        return app.processIdentifier
    }

    private static func intParam(_ params: [String: Value], _ key: String, default fallback: Int) -> Int {
        guard let v = params[key] else { return fallback }
        switch v {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        default:             return fallback
        }
    }

    private static func stringParam(_ params: [String: Value], _ key: String) -> String? {
        if case .string(let s) = params[key] { return s }
        return nil
    }

    private static func boolParam(_ params: [String: Value], _ key: String, default fallback: Bool) -> Bool {
        guard let v = params[key] else { return fallback }
        if case .bool(let b) = v { return b }
        return fallback
    }

    private static func unwrap(_ arguments: Value) -> [String: Value] {
        if case .object(let a) = arguments { return a }
        return [:]
    }

    // MARK: - Element Attribute Readers

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var val: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &val) == .success ? val : nil
    }

    private static func strAttr(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    private static func role(_ el: AXUIElement) -> String {
        strAttr(el, kAXRoleAttribute as String) ?? "Unknown"
    }

    private static func title(_ el: AXUIElement) -> String? {
        strAttr(el, kAXTitleAttribute as String)
    }

    private static func desc(_ el: AXUIElement) -> String? {
        strAttr(el, kAXDescriptionAttribute as String)
    }

    private static func label(_ el: AXUIElement) -> String? {
        title(el) ?? desc(el) ?? strAttr(el, kAXValueAttribute as String)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func position(_ el: AXUIElement) -> (x: Double, y: Double)? {
        guard let val = attr(el, kAXPositionAttribute as String) else { return nil }
        var pt = CGPoint.zero
        // PKT-373 P0-2: val is guaranteed AXValue by AX API when attr() succeeds
        AXValueGetValue(val as! AXValue, .cgPoint, &pt)
        return (Double(pt.x), Double(pt.y))
    }

    private static func size(_ el: AXUIElement) -> (w: Double, h: Double)? {
        guard let val = attr(el, kAXSizeAttribute as String) else { return nil }
        var sz = CGSize.zero
        // PKT-373 P0-2: val is guaranteed AXValue by AX API when attr() succeeds
        AXValueGetValue(val as! AXValue, .cgSize, &sz)
        return (Double(sz.width), Double(sz.height))
    }

    // MARK: - Tree Walking

    private static func elementDict(_ el: AXUIElement, depth: Int, maxDepth: Int,
                                     flat: Bool, path: String,
                                     results: inout [Value]) -> Value {
        let r = role(el)
        let t = title(el)
        let curPath = path.isEmpty ? "/\(r):\(t ?? "")" : "\(path)/\(r):\(t ?? "")"

        var d: [String: Value] = ["role": .string(r), "path": .string(curPath)]
        if let t = t          { d["title"] = .string(t) }
        if let ds = desc(el)  { d["description"] = .string(ds) }
        if let p = position(el) { d["x"] = .double(p.x); d["y"] = .double(p.y) }
        if let s = size(el)     { d["width"] = .double(s.w); d["height"] = .double(s.h) }

        if flat {
            results.append(.object(d))
            if depth < maxDepth {
                for child in children(el) {
                    _ = elementDict(child, depth: depth + 1, maxDepth: maxDepth,
                                    flat: true, path: curPath, results: &results)
                }
            }
            return .null
        } else {
            if depth < maxDepth {
                let kids = children(el)
                if !kids.isEmpty {
                    d["children"] = .array(kids.map {
                        elementDict($0, depth: depth + 1, maxDepth: maxDepth,
                                    flat: false, path: curPath, results: &results)
                    })
                }
            }
            return .object(d)
        }
    }

    // MARK: - Search

    private static func findElements(in el: AXUIElement, role r: String?, title t: String?,
                                      label l: String?, depth: Int, maxDepth: Int,
                                      path: String = "") -> [(AXUIElement, String)] {
        let er = role(el)
        let et = title(el)
        let elLabel = label(el)
        let cur = path.isEmpty ? "/\(er):\(et ?? "")" : "\(path)/\(er):\(et ?? "")"

        var out: [(AXUIElement, String)] = []

        var match = true
        if let r = r, er.lowercased() != r.lowercased() { match = false }
        if let t = t, !(et?.localizedCaseInsensitiveContains(t) ?? false) { match = false }
        if let l = l, !(elLabel?.localizedCaseInsensitiveContains(l) ?? false) { match = false }
        if match && (r != nil || t != nil || l != nil) { out.append((el, cur)) }

        if depth < maxDepth {
            for child in children(el) {
                out.append(contentsOf: findElements(in: child, role: r, title: t, label: l,
                                                     depth: depth + 1, maxDepth: maxDepth, path: cur))
            }
        }
        return out
    }

    // MARK: - Path Navigation

    private static func navigateToPath(_ root: AXUIElement, path: String) throws -> AXUIElement {
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        var current = root
        for (i, seg) in parts.enumerated() {
            if i == 0 { continue } // skip root app component
            let pieces = seg.split(separator: ":", maxSplits: 1)
            let wantRole = String(pieces[0])
            let wantTitle: String? = pieces.count > 1 ? String(pieces[1]) : nil

            var found = false
            for child in children(current) {
                if role(child) == wantRole && (wantTitle == nil || title(child) == wantTitle) {
                    current = child; found = true; break
                }
            }
            if !found { throw AXModuleError.elementNotFound(query: String(seg)) }
        }
        return current
    }

    // MARK: - Deep Inspect

    private static func detailedInfo(_ el: AXUIElement) -> Value {
        var d: [String: Value] = ["role": .string(role(el))]
        if let t = title(el)  { d["title"] = .string(t) }
        if let ds = desc(el)  { d["description"] = .string(ds) }
        if let v = strAttr(el, kAXValueAttribute as String) { d["value"] = .string(v) }
        if let p = position(el) { d["x"] = .double(p.x); d["y"] = .double(p.y) }
        if let s = size(el)     { d["width"] = .double(s.w); d["height"] = .double(s.h) }

        if let en = attr(el, kAXEnabledAttribute as String) as? Bool { d["enabled"] = .bool(en) }
        if let fo = attr(el, kAXFocusedAttribute as String) as? Bool { d["focused"] = .bool(fo) }
        if let se = attr(el, kAXSelectedAttribute as String) as? Bool { d["selected"] = .bool(se) }
        if let rv = strAttr(el, kAXRoleDescriptionAttribute as String) { d["roleDescription"] = .string(rv) }
        if let hp = strAttr(el, kAXHelpAttribute as String) { d["help"] = .string(hp) }
        if let id = strAttr(el, kAXIdentifierAttribute as String) { d["identifier"] = .string(id) }
        if let sub = strAttr(el, kAXSubroleAttribute as String) { d["subrole"] = .string(sub) }

        var actRef: CFArray?
        if AXUIElementCopyActionNames(el, &actRef) == .success, let acts = actRef as? [String] {
            d["actions"] = .array(acts.map { .string($0) })
        }

        var nameRef: CFArray?
        if AXUIElementCopyAttributeNames(el, &nameRef) == .success, let names = nameRef as? [String] {
            d["attributes"] = .array(names.map { .string($0) })
        }

        return .object(d)
    }

    // MARK: - Resolve Target Element

    private static func resolveTarget(_ params: [String: Value], appElement: AXUIElement) throws -> AXUIElement {
        if let path = stringParam(params, "path") {
            return try navigateToPath(appElement, path: path)
        }
        let r = stringParam(params, "role")
        let t = stringParam(params, "title")
        guard r != nil || t != nil else {
            throw AXModuleError.invalidInput("Provide 'path' or at least one of 'role'/'title'")
        }
        let matches = findElements(in: appElement, role: r, title: t, label: nil,
                                    depth: 0, maxDepth: 10)
        guard let (el, _) = matches.first else {
            throw AXModuleError.elementNotFound(query: "\(r ?? ""):\(t ?? "")")
        }
        return el
    }

    // MARK: - PKT-755 — Mode Payload Helpers
    //
    // Canonical payload bodies for the three collapsed AX query modes. Both
    // ax_query (new tool, no warning) and the deprecated shims route through
    // these so output shape is identical across the v2.2 ramp. The shims layer
    // a `_deprecated` warning on top via `withDeprecationWarning(_:)`; the new
    // tool returns the bare payload.

    private static func focusedAppPayload() -> Value {
        do {
            let (appEl, app) = try focusedApp()
            var result: [String: Value] = [
                "name":     .string(app.localizedName ?? "Unknown"),
                "bundleId": .string(app.bundleIdentifier ?? "Unknown"),
                "pid":      .int(Int(app.processIdentifier))
            ]
            if let fe = attr(appEl, kAXFocusedUIElementAttribute as String) as! AXUIElement? { // Safe: CF bridging
                result["focusedElement"] = .object([
                    "role":  .string(role(fe)),
                    "title": .string(title(fe) ?? ""),
                    "description": .string(desc(fe) ?? "")
                ])
            }
            return .object(result)
        } catch let e as AXModuleError { return e.toResponse() } catch { return .object(["error": .string("Unexpected: \(error)")]) }
    }

    private static func findElementPayload(params: [String: Value]) -> Value {
        do {
            let pid = try resolvePid(params)
            let r = stringParam(params, "role")
            let t = stringParam(params, "title")
            let l = stringParam(params, "label")
            let maxD = intParam(params, "maxDepth", default: 10)

            guard r != nil || t != nil || l != nil else {
                throw AXModuleError.invalidInput("At least one of role, title, or label is required")
            }

            let appEl = AXUIElementCreateApplication(pid)
            let matches = findElements(in: appEl, role: r, title: t, label: l,
                                        depth: 0, maxDepth: maxD)
            let elements: [Value] = matches.map { (el, path) in
                var d: [String: Value] = ["role": .string(role(el)), "path": .string(path)]
                if let t = title(el)    { d["title"] = .string(t) }
                if let ds = desc(el)    { d["description"] = .string(ds) }
                if let p = position(el) { d["x"] = .double(p.x); d["y"] = .double(p.y) }
                if let s = size(el)     { d["width"] = .double(s.w); d["height"] = .double(s.h) }
                return .object(d)
            }
            return .object(["matches": .array(elements), "count": .int(elements.count)])
        } catch let e as AXModuleError { return e.toResponse() } catch { return .object(["error": .string("Unexpected: \(error)")]) }
    }

    private static func elementInfoPayload(params: [String: Value]) -> Value {
        do {
            let pid = try resolvePid(params)
            let appEl = AXUIElementCreateApplication(pid)
            let target = try resolveTarget(params, appElement: appEl)
            return detailedInfo(target)
        } catch let e as AXModuleError { return e.toResponse() } catch { return .object(["error": .string("Unexpected: \(error)")]) }
    }

    /// PKT-755: layer a `_deprecated` marker over a payload from one of the
    /// three collapsed tools. Existing tool responses are always `.object`
    /// (success or `{error: ...}`), so this is shape-preserving on both paths.
    private static func withDeprecationWarning(_ value: Value) -> Value {
        guard case .object(var dict) = value else { return value }
        dict["_deprecated"] = .string(deprecationWarning)
        return .object(dict)
    }

    // MARK: - Tool Registration

    public static func register(on router: ToolRouter) async {

        // ── 1. ax_inspect (open) — Sprint A · #11 rename of ax_query ─────
        // PKT-755 unified ax_focused_app + ax_find_element + ax_element_info
        // into ax_query; Sprint A renames that umbrella to the action-verb
        // canonical ax_inspect. ax_query stays as a one-cycle alias.
        let axInspect = ToolRegistration(
            name: "ax_inspect",
            module: moduleName,
            tier: .open,
            description: "Inspect macOS accessibility (AX) elements. mode='focused_app' returns the frontmost app + its focused element. mode='find_element' locates AX elements by role/title/label and returns matching paths. mode='element_info' inspects one element's full attributes, available actions, geometry, and state. Companion to ax_tree (full dump) and ax_perform_action (actuation).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode":     .object(["type": .string("string"),  "enum": .array([.string("focused_app"), .string("find_element"), .string("element_info")]), "description": .string("Query mode: focused_app | find_element | element_info")]),
                    "pid":      .object(["type": .string("integer"), "description": .string("Process ID. Omit for frontmost app. Used by find_element / element_info modes.")]),
                    "role":     .object(["type": .string("string"),  "description": .string("AX role (e.g. AXButton). find_element: substring match; element_info: alternative to path.")]),
                    "title":    .object(["type": .string("string"),  "description": .string("Title substring (find_element, case-insensitive) or exact title (element_info, alternative to path).")]),
                    "label":    .object(["type": .string("string"),  "description": .string("Label/description substring to match (find_element only, case-insensitive).")]),
                    "path":     .object(["type": .string("string"),  "description": .string("Element path, e.g. /AXApplication:Finder/AXWindow:Downloads/AXButton:Close (element_info only).")]),
                    "maxDepth": .object(["type": .string("integer"), "description": .string("Max search depth (find_element only, default: 10).")])
                ]),
                "required": .array([.string("mode")])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                guard let mode = stringParam(params, "mode") else {
                    return AXModuleError.invalidInput("'mode' is required (focused_app | find_element | element_info)").toResponse()
                }
                switch mode {
                case "focused_app":
                    return focusedAppPayload()
                case "find_element":
                    return findElementPayload(params: params)
                case "element_info":
                    return elementInfoPayload(params: params)
                default:
                    return AXModuleError.invalidInput("Unknown mode '\(mode)'. Expected: focused_app | find_element | element_info").toResponse()
                }
            }
        )
        await router.register(axInspect)
        // One-cycle deprecation alias under the old name.
        await router.register(ToolDeprecationAlias.renameAlias(
            oldName: "ax_query", newName: "ax_inspect", from: axInspect
        ))

        // ── 2. ax_focused_app (open) — Sprint A · #11 REVIVAL ─────────────
        // Promoted from "mode='focused_app'" to its own top-level tool
        // because frontmost-app introspection is hit often enough to deserve
        // a dedicated, zero-arg call site (audit §3-question #2 acknowledged
        // the optics of reviving a deprecated name — see report).
        await router.register(ToolRegistration(
            name: "ax_focused_app",
            module: moduleName,
            tier: .open,
            description: "Return the frontmost macOS app's name, bundleId, and pid (+ its focused element when AX permission is granted). First step before any other ax_* call. Equivalent to `ax_inspect mode='focused_app'` but takes no arguments and is faster to discover.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            handler: { _ in
                focusedAppPayload()
            }
        ))

        // ── 3. ax_tree (open) ─────────────────────────────────────────────
        await router.register(ToolRegistration(
            name: "ax_tree",
            module: moduleName,
            tier: .open,
            description: "Dump the full AX element tree for one app. Expensive — cap with maxDepth. Use ax_inspect (mode='find_element') for targeted lookups.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pid":      .object(["type": .string("integer"), "description": .string("Process ID. Omit for frontmost app.")]),
                    "maxDepth": .object(["type": .string("integer"), "description": .string("Max traversal depth (default: 5)")]),
                    "flat":     .object(["type": .string("boolean"), "description": .string("Return flat array instead of tree (default: false)")])
                ])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                do {
                    let pid = try resolvePid(params)
                    let maxD = intParam(params, "maxDepth", default: 5)
                    let flat = boolParam(params, "flat", default: false)
                    let appEl = AXUIElementCreateApplication(pid)
                    guard let appName = NSRunningApplication(processIdentifier: pid)?.localizedName else {
                        throw AXModuleError.appNotFound(pid: pid)
                    }

                    var flatResults: [Value] = []
                    let tree = elementDict(appEl, depth: 0, maxDepth: maxD,
                                           flat: flat, path: "", results: &flatResults)

                    var out: [String: Value] = ["app": .string(appName), "pid": .int(Int(pid))]
                    if flat {
                        out["elements"] = .array(flatResults)
                        out["count"]    = .int(flatResults.count)
                    } else {
                        out["tree"] = tree
                    }
                    return .object(out)
                } catch let e as AXModuleError { return e.toResponse() }
            }
        ))

        // Sprint A · mcp-builder #1: ax_find_element / ax_element_info
        // DEPRECATED shims removed (PKT-755 v2.2 ramp complete; audit allows
        // full removal). Callers must use ax_query with the appropriate
        // mode= value; the payload helpers (findElementPayload /
        // elementInfoPayload) are unchanged.

        // ── 6. ax_perform_action (notify) ─────────────────────────────────
        await router.register(ToolRegistration(
            name: "ax_perform_action",
            module: moduleName,
            tier: .notify,
            description: "Execute an action (press/focus/setValue/confirm/cancel/increment/decrement) on a located AX element. Priority 1 on the app-control cascade.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pid":    .object(["type": .string("integer"), "description": .string("Process ID. Omit for frontmost app.")]),
                    "path":   .object(["type": .string("string"),  "description": .string("Element path to act on")]),
                    "role":   .object(["type": .string("string"),  "description": .string("Role to find (alternative to path)")]),
                    "title":  .object(["type": .string("string"),  "description": .string("Title to find (alternative to path)")]),
                    "action": .object(["type": .string("string"),  "description": .string("Action: press, focus, setValue, confirm, cancel, increment, decrement, or raw AX action name")]),
                    "value":  .object(["type": .string("string"),  "description": .string("Value to set (required for setValue action)")])
                ]),
                "required": .array([.string("action")])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                do {
                    try ensureTrusted()
                    let pid = try resolvePid(params)
                    guard let action = stringParam(params, "action") else {
                        throw AXModuleError.invalidInput("action is required")
                    }

                    let appEl = AXUIElementCreateApplication(pid)
                    let target = try resolveTarget(params, appElement: appEl)

                    // Map friendly names to AX constants
                    switch action.lowercased() {
                    case "setvalue":
                        guard let newVal = stringParam(params, "value") else {
                            throw AXModuleError.invalidInput("value is required for setValue action")
                        }
                        let res = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, newVal as CFTypeRef)
                        guard res == .success else {
                            throw AXModuleError.actionFailed(action: "setValue", detail: "AXError code \(res.rawValue)")
                        }
                        return .object(["success": .bool(true), "action": .string("setValue"), "value": .string(newVal)])

                    default:
                        let axAction: String
                        switch action.lowercased() {
                        case "press":     axAction = kAXPressAction as String
                        case "focus":     axAction = kAXRaiseAction as String
                        case "confirm":   axAction = kAXConfirmAction as String
                        case "cancel":    axAction = kAXCancelAction as String
                        case "increment": axAction = kAXIncrementAction as String
                        case "decrement": axAction = kAXDecrementAction as String
                        default:          axAction = action
                        }

                        let res = AXUIElementPerformAction(target, axAction as CFString)
                        guard res == .success else {
                            throw AXModuleError.actionFailed(action: action, detail: "AXError code \(res.rawValue)")
                        }
                        return .object([
                            "success": .bool(true),
                            "action":  .string(action),
                            "element": .string("\(role(target)):\(title(target) ?? "")")
                        ])
                    }
                } catch let e as AXModuleError { return e.toResponse() }
            }
        ))
    }
}
