// SyntheticInputModule.swift — Synthetic keyboard input via CGEvent
// NotionBridge · Modules
//
// PKT-747 (v2.2 · 3.3) — MAC UI extras.
//
// Initial scope of this packet: keyboard_type. The remaining synthetic-input
// surface (mouse_click, cgevent_send) and the pasteboard primitive
// (pasteboard_history) split out to follow-up packet PKT-3.3.1 per the
// Reflow Protocol §4 Type A pattern (PM-decisive REVIEW disposition).
//
// macOS 26 Tahoe permission model:
//   - Synthetic input requires the host app to be granted Accessibility AND
//     Input Monitoring TCC entitlements.
//   - First-run path: AXIsProcessTrusted() == false → tool returns
//     `capability_missing` immediately with a settings deep-link hint. The
//     existing PermissionView surface (used by AccessibilityModule) remains
//     the user-facing path; this module never silently no-ops.
//
// CGEvent reference: keyboardSetUnicodeString posts the full Unicode plane
// without virtual-keycode mapping, which is the right primitive for arbitrary
// text in AX-incompatible apps (Adobe-class).

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import MCP

public enum SyntheticInputModule {
    public static let moduleName = "computer"

    // MARK: - Errors

    private enum SynthError: Error {
        case notTrusted
        case invalidInput(String)
        case eventCreateFailed(String)

        func toResponse() -> Value {
            switch self {
            case .notTrusted:
                return .object([
                    "error": .string("capability_missing: Accessibility + Input Monitoring permissions required for synthetic input. Open System Settings > Privacy & Security > Accessibility and grant Notion Bridge."),
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

    // MARK: - Helpers

    private static func unwrap(_ arguments: Value) -> [String: Value] {
        if case .object(let a) = arguments { return a }
        return [:]
    }

    private static func stringParam(_ params: [String: Value], _ key: String) -> String? {
        if case .string(let s) = params[key] { return s }
        return nil
    }

    private static func intParam(_ params: [String: Value], _ key: String, default fallback: Int) -> Int {
        guard let v = params[key] else { return fallback }
        switch v {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        default:             return fallback
        }
    }

    private static func ensureTrusted() throws {
        // AXIsProcessTrusted gates the synthetic-input path on macOS 26 Tahoe.
        // Input Monitoring is a separate TCC class but CGEventPost() inherits
        // from the Accessibility grant for keyboard/mouse synthesis on this
        // platform; sites that need Input Monitoring specifically (e.g. raw
        // hot-key listeners) are out of scope for this packet.
        guard AXIsProcessTrusted() else { throw SynthError.notTrusted }
    }

    /// Post one Unicode chunk as a key-down + key-up pair using
    /// keyboardSetUnicodeString on a virtualKey:0 event. Up to ~20 UTF-16
    /// code units fit per event safely; longer text is chunked.
    private static func postUnicode(_ text: String, delayMs: Int) throws -> (chars: Int, utf16: Int) {
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw SynthError.eventCreateFailed("CGEventSource(.hidSystemState) returned nil")
        }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var idx = 0

        while idx < utf16.count {
            let end = min(idx + chunkSize, utf16.count)
            let chunk = Array(utf16[idx..<end])

            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else {
                throw SynthError.eventCreateFailed("keyDown event")
            }
            chunk.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)

            guard let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
                throw SynthError.eventCreateFailed("keyUp event")
            }
            chunk.withUnsafeBufferPointer { buf in
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
            }
            up.post(tap: .cghidEventTap)

            idx = end
            if delayMs > 0 && idx < utf16.count {
                Thread.sleep(forTimeInterval: TimeInterval(delayMs) / 1000.0)
            }
        }

        return (chars: text.count, utf16: utf16.count)
    }

    // MARK: - Registration

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "keyboard_type",
            module: moduleName,
            tier: .notify,
            description: "Synthetic typing via CGEvent — Unicode-safe, works against AX-incompatible apps (Adobe-class). Requires Accessibility + Input Monitoring TCC grants. Returns code='capability_missing' on permission denial (never silent fail).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text":    .object(["type": .string("string"),  "description": .string("Text to type. Full Unicode supported (handled via CGEvent keyboardSetUnicodeString, no vk-mapping).")]),
                    "delayMs": .object(["type": .string("integer"), "description": .string("Inter-chunk delay in milliseconds (default: 0). Use 5–15 for apps that drop characters at full speed.")])
                ]),
                "required": .array([.string("text")])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                guard let text = stringParam(params, "text") else {
                    return SynthError.invalidInput("text is required").toResponse()
                }
                let delayMs = max(0, intParam(params, "delayMs", default: 0))

                do {
                    try ensureTrusted()
                    if text.isEmpty {
                        return .object([
                            "success":    .bool(true),
                            "characters": .int(0),
                            "utf16Units": .int(0),
                            "note":       .string("Empty text — no events posted.")
                        ])
                    }
                    let stats = try postUnicode(text, delayMs: delayMs)
                    return .object([
                        "success":    .bool(true),
                        "characters": .int(stats.chars),
                        "utf16Units": .int(stats.utf16)
                    ])
                } catch let e as SynthError {
                    return e.toResponse()
                } catch {
                    return .object(["error": .string("Unexpected: \(error)")])
                }
            }
        ))
    }
}
