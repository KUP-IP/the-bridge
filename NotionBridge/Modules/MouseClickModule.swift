// MouseClickModule.swift — Synthetic mouse clicks via CGEvent
// NotionBridge · Modules
//
// PKT-765 (v2.2 · 3.3.1) — MAC UI extras Wave 2.
//
// Companion to SyntheticInputModule (keyboard_type, PKT-747). Posts CGEvent
// mouse-down/-up pairs at absolute screen coordinates OR window-relative
// coordinates (front window of the focused app, resolved via AX).
//
// Permissions: Accessibility (AX) — same gate as keyboard_type.
// First-run path: AXIsProcessTrusted() == false → capability_missing with
// settings deep-link. Never silently no-ops.

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import MCP

public enum MouseClickModule {
    public static let moduleName = "computer"

    // MARK: - Errors

    private enum MouseError: Error {
        case notTrusted
        case invalidInput(String)
        case eventCreateFailed(String)
        case windowLookupFailed(String)

        func toResponse() -> Value {
            switch self {
            case .notTrusted:
                return .object([
                    "error": .string("capability_missing: Accessibility permissions required for synthetic mouse input. Open System Settings > Privacy & Security > Accessibility and grant Notion Bridge."),
                    "code":          .string("capability_missing"),
                    "settingsHint":  .string("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                ])
            case .invalidInput(let detail):
                return .object([
                    "error": .string("Invalid input: \(detail)"),
                    "code":  .string("invalid_input")
                ])
            case .eventCreateFailed(let detail):
                return .object([
                    "error": .string("Failed to create CGEvent: \(detail)"),
                    "code":  .string("event_create_failed")
                ])
            case .windowLookupFailed(let detail):
                return .object([
                    "error": .string("Window lookup failed: \(detail)"),
                    "code":  .string("window_lookup_failed")
                ])
            }
        }
    }

    // MARK: - Param helpers

    private static func unwrap(_ arguments: Value) -> [String: Value] {
        if case .object(let a) = arguments { return a }
        return [:]
    }
    private static func stringParam(_ p: [String: Value], _ k: String) -> String? {
        if case .string(let s) = p[k] { return s }
        return nil
    }
    private static func intParam(_ p: [String: Value], _ k: String, default fb: Int) -> Int {
        guard let v = p[k] else { return fb }
        switch v {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        default:             return fb
        }
    }
    private static func doubleParam(_ p: [String: Value], _ k: String) -> Double? {
        guard let v = p[k] else { return nil }
        switch v {
        case .int(let i):    return Double(i)
        case .double(let d): return d
        default:             return nil
        }
    }
    private static func boolParam(_ p: [String: Value], _ k: String, default fb: Bool) -> Bool {
        guard let v = p[k] else { return fb }
        if case .bool(let b) = v { return b }
        return fb
    }

    private static func ensureTrusted() throws {
        guard AXIsProcessTrusted() else { throw MouseError.notTrusted }
    }

    /// Look up the frame (in screen coordinates, top-left origin) of the
    /// focused window of the focused application, via AX.
    private static func focusedWindowFrame() throws -> CGRect {
        let sys = AXUIElementCreateSystemWide()
        var focusedAppRef: AnyObject?
        let appErr = AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &focusedAppRef)
        guard appErr == .success, let focusedAppCF = focusedAppRef else {
            throw MouseError.windowLookupFailed("No focused application (AX err=\(appErr.rawValue))")
        }
        let app = focusedAppCF as! AXUIElement

        var focusedWindowRef: AnyObject?
        let winErr = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        guard winErr == .success, let focusedWindowCF = focusedWindowRef else {
            throw MouseError.windowLookupFailed("No focused window (AX err=\(winErr.rawValue))")
        }
        let window = focusedWindowCF as! AXUIElement

        var posRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard let posVal = posRef, let sizeVal = sizeRef else {
            throw MouseError.windowLookupFailed("Missing position/size on focused window")
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func cgButton(from name: String) -> CGMouseButton? {
        switch name.lowercased() {
        case "left":              return .left
        case "right":             return .right
        case "center", "middle":  return .center
        default:                  return nil
        }
    }

    private static func eventTypes(for button: CGMouseButton) -> (down: CGEventType, up: CGEventType) {
        switch button {
        case .left:   return (.leftMouseDown,  .leftMouseUp)
        case .right:  return (.rightMouseDown, .rightMouseUp)
        case .center: return (.otherMouseDown, .otherMouseUp)
        @unknown default: return (.otherMouseDown, .otherMouseUp)
        }
    }

    private static func postClick(at point: CGPoint, button: CGMouseButton, clickCount: Int) throws {
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw MouseError.eventCreateFailed("CGEventSource(.hidSystemState) returned nil")
        }
        let (downType, upType) = eventTypes(for: button)

        for _ in 0..<max(1, clickCount) {
            guard let down = CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: point, mouseButton: button) else {
                throw MouseError.eventCreateFailed("mouseDown event")
            }
            if clickCount > 1 {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            }
            down.post(tap: .cghidEventTap)

            guard let up = CGEvent(mouseEventSource: src, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                throw MouseError.eventCreateFailed("mouseUp event")
            }
            if clickCount > 1 {
                up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            }
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Registration

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "mouse_click",
            module: moduleName,
            tier: .notify,
            description: "Synthetic mouse click via CGEvent at absolute screen coordinates or window-relative coordinates (front window of the focused app, resolved via AX). Supports left/right/middle buttons and 1- or 2-click sequences. Requires Accessibility TCC grant. Returns code='capability_missing' on permission denial.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x":              .object(["type": .string("number"),  "description": .string("X coordinate (absolute screen pixels, top-left origin) OR window-relative offset when windowRelative=true.")]),
                    "y":              .object(["type": .string("number"),  "description": .string("Y coordinate (absolute screen pixels, top-left origin) OR window-relative offset when windowRelative=true.")]),
                    "button":         .object(["type": .string("string"),  "description": .string("Mouse button: 'left' (default), 'right', or 'middle'/'center'.")]),
                    "clickCount":     .object(["type": .string("integer"), "description": .string("Number of clicks in the sequence (1 = single, 2 = double). Default 1.")]),
                    "windowRelative": .object(["type": .string("boolean"), "description": .string("If true, (x,y) is interpreted relative to the focused window's top-left corner (resolved via AX). Default false (absolute screen coords).")])
                ]),
                "required": .array([.string("x"), .string("y")])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                guard let xv = doubleParam(params, "x") else {
                    return MouseError.invalidInput("x is required (number)").toResponse()
                }
                guard let yv = doubleParam(params, "y") else {
                    return MouseError.invalidInput("y is required (number)").toResponse()
                }
                let buttonName = stringParam(params, "button") ?? "left"
                guard let button = cgButton(from: buttonName) else {
                    return MouseError.invalidInput("button must be 'left' | 'right' | 'middle' | 'center', got '\(buttonName)'").toResponse()
                }
                let clickCount = max(1, min(intParam(params, "clickCount", default: 1), 3))
                let windowRel  = boolParam(params, "windowRelative", default: false)

                do {
                    try ensureTrusted()

                    let target: CGPoint
                    if windowRel {
                        let frame = try focusedWindowFrame()
                        target = CGPoint(x: frame.origin.x + xv, y: frame.origin.y + yv)
                    } else {
                        target = CGPoint(x: xv, y: yv)
                    }

                    try postClick(at: target, button: button, clickCount: clickCount)

                    return .object([
                        "success":        .bool(true),
                        "x":              .double(target.x),
                        "y":              .double(target.y),
                        "button":         .string(buttonName.lowercased()),
                        "clickCount":     .int(clickCount),
                        "windowRelative": .bool(windowRel)
                    ])
                } catch let e as MouseError {
                    return e.toResponse()
                } catch {
                    return .object(["error": .string("Unexpected: \(error)")])
                }
            }
        ))
    }
}
