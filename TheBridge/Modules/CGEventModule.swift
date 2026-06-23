// CGEventModule.swift — Raw CGEvent escape hatch (cliclick-equivalent)
// TheBridge · Modules
//
// PKT-765 (v2.2 · 3.3.1) — MAC UI extras Wave 2.
//
// Power-user surface for arbitrary CGEvent construction not covered by the
// higher-level keyboard_type and mouse_click tools. Supports key press/down/up
// with virtual key code + modifier flags, plus scroll wheel events.
//
// Permissions: Accessibility (AX). Same gate as keyboard_type / mouse_click.
// First-run path: AXIsProcessTrusted() == false → capability_missing with
// settings deep-link. Never silently no-ops.

import Foundation
import CoreGraphics
import ApplicationServices
import MCP

public enum CGEventModule {
    public static let moduleName = "computer"

    // MARK: - Errors

    private enum CGEvErr: Error {
        case notTrusted
        case invalidInput(String)
        case eventCreateFailed(String)

        func toResponse() -> Value {
            switch self {
            case .notTrusted:
                return .object([
                    "error": .string("capability_missing: Accessibility permissions required to post CGEvents. Open System Settings > Privacy & Security > Accessibility and grant The Bridge."),
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
    private static func doubleParam(_ p: [String: Value], _ k: String, default fb: Double) -> Double {
        guard let v = p[k] else { return fb }
        switch v {
        case .int(let i):    return Double(i)
        case .double(let d): return d
        default:             return fb
        }
    }
    private static func arrayParam(_ p: [String: Value], _ k: String) -> [Value]? {
        if case .array(let a) = p[k] { return a }
        return nil
    }

    private static func parseFlags(_ raw: [Value]) -> CGEventFlags {
        var f = CGEventFlags()
        for v in raw {
            guard case .string(let s) = v else { continue }
            switch s.lowercased() {
            case "cmd", "command":       f.insert(.maskCommand)
            case "shift":                f.insert(.maskShift)
            case "opt", "alt", "option": f.insert(.maskAlternate)
            case "ctrl", "control":      f.insert(.maskControl)
            case "fn":                   f.insert(.maskSecondaryFn)
            case "caps", "capslock":     f.insert(.maskAlphaShift)
            default: break
            }
        }
        return f
    }

    private static func ensureTrusted() throws {
        guard AXIsProcessTrusted() else { throw CGEvErr.notTrusted }
    }

    private static func postKey(keyCode: Int, isDown: Bool, flags: CGEventFlags) throws {
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw CGEvErr.eventCreateFailed("CGEventSource(.hidSystemState) returned nil")
        }
        guard let evt = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: isDown) else {
            throw CGEvErr.eventCreateFailed("CGEvent keyboard (keyCode=\(keyCode), down=\(isDown))")
        }
        if !flags.isEmpty {
            evt.flags = flags
        }
        evt.post(tap: .cghidEventTap)
    }

    private static func postScroll(dx: Double, dy: Double) throws {
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw CGEvErr.eventCreateFailed("CGEventSource(.hidSystemState) returned nil")
        }
        guard let evt = CGEvent(scrollWheelEvent2Source: src,
                                units: .pixel,
                                wheelCount: 2,
                                wheel1: Int32(dy),
                                wheel2: Int32(dx),
                                wheel3: 0) else {
            throw CGEvErr.eventCreateFailed("Scroll wheel event")
        }
        evt.post(tap: .cghidEventTap)
    }

    // MARK: - Registration

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "cgevent_send",
            module: moduleName,
            tier: .notify,
            description: "Raw CGEvent escape hatch — construct arbitrary keyboard and scroll events not covered by keyboard_type/mouse_click. Supports key_down/key_up/key_press with virtual key code + modifier flags, and scroll events with delta x/y. cliclick-equivalent. Requires Accessibility TCC grant.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "type":         .object(["type": .string("string"),  "description": .string("Event type: 'key_down' | 'key_up' | 'key_press' (down+up) | 'scroll'.")]),
                    "keyCode":      .object(["type": .string("integer"), "description": .string("CGKeyCode virtual key code (required for key_* types). See <HIToolbox/Events.h> kVK_* constants.")]),
                    "flags":        .object(["type": .string("array"),   "description": .string("Modifier flags array, any of: 'cmd' | 'shift' | 'opt' | 'ctrl' | 'fn' | 'capslock'. Empty for none.")]),
                    "scrollDeltaX": .object(["type": .string("number"),  "description": .string("Horizontal scroll delta in pixels (negative = left). Required for type=scroll.")]),
                    "scrollDeltaY": .object(["type": .string("number"),  "description": .string("Vertical scroll delta in pixels (negative = down). Required for type=scroll.")])
                ]),
                "required": .array([.string("type")])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                guard let type = stringParam(params, "type") else {
                    return CGEvErr.invalidInput("type is required").toResponse()
                }
                let flagsRaw = arrayParam(params, "flags") ?? []
                let flags = parseFlags(flagsRaw)

                do {
                    try ensureTrusted()

                    switch type.lowercased() {
                    case "key_down":
                        let kc = intParam(params, "keyCode", default: -1)
                        guard kc >= 0 else { return CGEvErr.invalidInput("keyCode is required for key_down").toResponse() }
                        try postKey(keyCode: kc, isDown: true, flags: flags)
                        return .object(["success": .bool(true), "type": .string("key_down"), "keyCode": .int(kc)])
                    case "key_up":
                        let kc = intParam(params, "keyCode", default: -1)
                        guard kc >= 0 else { return CGEvErr.invalidInput("keyCode is required for key_up").toResponse() }
                        try postKey(keyCode: kc, isDown: false, flags: flags)
                        return .object(["success": .bool(true), "type": .string("key_up"), "keyCode": .int(kc)])
                    case "key_press":
                        let kc = intParam(params, "keyCode", default: -1)
                        guard kc >= 0 else { return CGEvErr.invalidInput("keyCode is required for key_press").toResponse() }
                        try postKey(keyCode: kc, isDown: true,  flags: flags)
                        try postKey(keyCode: kc, isDown: false, flags: flags)
                        return .object(["success": .bool(true), "type": .string("key_press"), "keyCode": .int(kc)])
                    case "scroll":
                        let dx = doubleParam(params, "scrollDeltaX", default: 0)
                        let dy = doubleParam(params, "scrollDeltaY", default: 0)
                        try postScroll(dx: dx, dy: dy)
                        return .object([
                            "success":      .bool(true),
                            "type":         .string("scroll"),
                            "scrollDeltaX": .double(dx),
                            "scrollDeltaY": .double(dy)
                        ])
                    default:
                        return CGEvErr.invalidInput("type must be 'key_down' | 'key_up' | 'key_press' | 'scroll', got '\(type)'").toResponse()
                    }
                } catch let e as CGEvErr {
                    return e.toResponse()
                } catch {
                    return .object(["error": .string("Unexpected: \(error)")])
                }
            }
        ))
    }
}
