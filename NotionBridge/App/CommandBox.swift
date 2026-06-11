// CommandBox.swift — Commands palette (clipboard-only) — reusable types
// NotionBridge · App
//
// PKT-878 v3.6.3: the legacy NSTableView-backed `CommandBoxController` +
// `CommandBoxPanel` were RETIRED in favour of the new SwiftUI Liquid
// Glass implementation in `CommandBridge.swift` (controller name:
// `CommandBridgeController`, panel name: `CommandBridgePanel`). What
// remains in this file is the share-by-import, GUI-free surface the new
// controller and its tests still consume verbatim:
//
//   • HotkeyConfig            — Carbon RegisterEventHotKey config + persisted
//                                 load/save + Cocoa→Carbon recorder mapping
//   • ClipboardWriting        — protocol seam over NSPasteboard (write-only)
//   • InMemoryClipboard       — test double (write + read-back + write count)
//   • SystemClipboard         — NSPasteboard.general adapter (replace contents)
//
// PERMISSION MODEL (unchanged): Carbon `RegisterEventHotKey` is a HOT-KEY
// REGISTRATION, not an event tap — no Input Monitoring or Accessibility
// TCC grant. The pasteboard write needs no TCC grant either. With
// paste-back deleted years ago, there is no CGEvent synthesis anywhere.

import Foundation
import AppKit
import Carbon.HIToolbox

// ============================================================
// MARK: - 1a. HotkeyConfig (pure)
// ============================================================

/// Carbon hot-key configuration. Maps to `RegisterEventHotKey`'s
/// (keyCode, modifierFlags) pair. Modifier mask uses the Carbon
/// `*Key` constants (cmdKey/optionKey/controlKey/shiftKey), NOT the
/// Cocoa `NSEvent.ModifierFlags` bitset — they are different bit layouts.
public struct HotkeyConfig: Equatable, Sendable, Codable {
    /// Carbon virtual key code (e.g. `kVK_Space` = 49).
    public let keyCode: UInt32
    /// Carbon modifier mask (OR of cmdKey/optionKey/controlKey/shiftKey).
    public let carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// The original spike default: ⌥⌘Space (Option+Command+Space).
    /// RETAINED only so historical references / Codable fixtures stay
    /// valid — the SHIPPING default is `productionDefault` (⌃⌘B). Chosen
    /// originally to avoid Spotlight (⌘Space) and macOS dictation.
    public static let spikeDefault = HotkeyConfig(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(cmdKey | optionKey)
    )

    /// The SHIPPING production default: ⌃⌘B (Control+Command+B) — "B for Bridge".
    /// Carbon `kVK_ANSI_B` (11) + `controlKey | cmdKey`. A front-and-center,
    /// two-modifier combo: ⌃⌘ is almost untouched by macOS/apps, so ⌃⌘B is
    /// collision-resistant while staying memorable and easy to hit one-handed
    /// from either side. `hasModifier` is true so the controller registers it,
    /// and the in-Settings recorder lets the operator rebind it live if it ever
    /// conflicts on their machine.
    public static let productionDefault = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_B),
        carbonModifiers: UInt32(controlKey | cmdKey)
    )

    /// Whether at least one modifier is set. A modifier-less global
    /// hot-key is almost always wrong (it would swallow a bare key for
    /// every app) — the controller refuses to register one.
    public var hasModifier: Bool { carbonModifiers != 0 }

    /// Stable 4-char OSType signature for the Carbon `EventHotKeyID`.
    /// Carbon requires a non-zero signature+id to later unregister.
    public static let signature: OSType = {
        // 'NBcb' = NotionBridge command box
        let bytes: [UInt8] = [0x4E, 0x42, 0x63, 0x62]
        return bytes.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()

    /// Human-readable combo, for logging / smoke output / the Settings
    /// status row. Modifiers render in the canonical Apple order
    /// (⌃⌥⇧⌘), then the key glyph. ANSI letter / digit keys render as
    /// their uppercase character; Space stays "Space"; anything else
    /// degrades to `key#N`.
    public var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyGlyph(for: keyCode)
        return s
    }

    // ============================================================
    // MARK: Cocoa → Carbon recorder mapping (pure, Change B)
    // ============================================================

    /// Map a recorded key-down — its Carbon virtual `keyCode` plus the
    /// Cocoa `NSEvent.ModifierFlags` that were held — into a validated
    /// `HotkeyConfig`, or `nil` if the chord is REJECTED.
    ///
    /// This is the headlessly-testable heart of the in-Settings recorder
    /// (the actual `NSEvent` capture gesture is the operator-smoke
    /// ceiling; THIS mapping/validation is not). It does two jobs:
    ///
    ///   1. Translate the Cocoa modifier bitset (`.control/.option/
    ///      .shift/.command`) into the Carbon modifier mask
    ///      (`controlKey/optionKey/shiftKey/cmdKey`) — they are DIFFERENT
    ///      bit layouts, so a literal copy would silently mis-register.
    ///   2. Reject an invalid chord by returning `nil`:
    ///        • no modifier at all (a bare key would swallow that key for
    ///          every app — `CommandBridgeController.registerHotkey()` also
    ///          refuses it, but we reject earlier so the recorder never
    ///          even offers to persist it), and
    ///        • a "pure-modifier" press with no real key. A modifier-only
    ///          key-down (the recorder must wait for an actual key) has a
    ///          `keyCode` that is itself a modifier virtual key
    ///          (⌘/⌥/⌃/⇧/CapsLock/Fn); those are not bindable.
    ///
    /// Pure: no `NSEvent`, no GUI, no global state — `(keyCode, flags) →
    /// HotkeyConfig?` is a total function, unit-tested exhaustively.
    public static func from(
        keyCode: UInt32,
        cocoaModifiers: NSEvent.ModifierFlags
    ) -> HotkeyConfig? {
        // (2a) Reject a modifier-key-only press (no real key yet).
        if Self.isPureModifierKeyCode(keyCode) { return nil }

        // (1) Cocoa bitset → Carbon mask. `.deviceIndependentFlagsMask`
        // strips device/Fn noise so e.g. left/right ⌘ both map cleanly.
        let cocoa = cocoaModifiers.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if cocoa.contains(.control) { carbon |= UInt32(controlKey) }
        if cocoa.contains(.option)  { carbon |= UInt32(optionKey) }
        if cocoa.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if cocoa.contains(.command) { carbon |= UInt32(cmdKey) }

        // (2b) Reject a modifier-less chord (would hijack a bare key).
        guard carbon != 0 else { return nil }

        return HotkeyConfig(keyCode: keyCode, carbonModifiers: carbon)
    }

    /// True iff `keyCode` is itself a modifier / non-bindable virtual key
    /// (⌘/⌥/⌃/⇧/CapsLock/Fn, left or right). A recorder key-down with one
    /// of these is a "still holding modifiers, no key yet" event and must
    /// not become a hot-key. Pure + exhaustively unit-testable.
    public static func isPureModifierKeyCode(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand,
             kVK_Shift, kVK_RightShift,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_CapsLock, kVK_Function:
            return true
        default:
            return false
        }
    }

    // ============================================================
    // MARK: Persistence (Change B)
    // ============================================================

    /// Load the persisted Commands hot-key from `UserDefaults`, falling
    /// back to `productionDefault` when the key is unset OR the stored
    /// bytes fail to decode (corrupt write / schema drift). Pure given an
    /// injected `UserDefaults` so the fallback ladder is unit-tested with
    /// zero process-global coupling.
    public static func loadPersisted(
        from defaults: UserDefaults = .standard,
        key: String = BridgeDefaults.commandsHotkey
    ) -> HotkeyConfig {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(HotkeyConfig.self, from: data)
        else {
            return .productionDefault
        }
        return decoded
    }

    /// Persist this config as JSON under `key`. Returns `false` if
    /// encoding somehow fails (it cannot for this fixed shape, but the
    /// caller treats a false as "kept the prior registration"). Pure
    /// given an injected `UserDefaults`.
    @discardableResult
    public func persist(
        to defaults: UserDefaults = .standard,
        key: String = BridgeDefaults.commandsHotkey
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    /// Map a Carbon virtual key code to its display glyph. Pure +
    /// exhaustively unit-testable (no GUI). Covers Space and the ANSI
    /// letter row used by the shipping default (⌃⌘B → "B"); unknown codes
    /// fall back to `key#N` so the string is never empty.
    public static func keyGlyph(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space:   return "Space"
        case kVK_ANSI_A:  return "A"
        case kVK_ANSI_B:  return "B"
        case kVK_ANSI_C:  return "C"
        case kVK_ANSI_D:  return "D"
        case kVK_ANSI_E:  return "E"
        case kVK_ANSI_F:  return "F"
        case kVK_ANSI_G:  return "G"
        case kVK_ANSI_H:  return "H"
        case kVK_ANSI_I:  return "I"
        case kVK_ANSI_J:  return "J"
        case kVK_ANSI_K:  return "K"
        case kVK_ANSI_L:  return "L"
        case kVK_ANSI_M:  return "M"
        case kVK_ANSI_N:  return "N"
        case kVK_ANSI_O:  return "O"
        case kVK_ANSI_P:  return "P"
        case kVK_ANSI_Q:  return "Q"
        case kVK_ANSI_R:  return "R"
        case kVK_ANSI_S:  return "S"
        case kVK_ANSI_T:  return "T"
        case kVK_ANSI_U:  return "U"
        case kVK_ANSI_V:  return "V"
        case kVK_ANSI_W:  return "W"
        case kVK_ANSI_X:  return "X"
        case kVK_ANSI_Y:  return "Y"
        case kVK_ANSI_Z:  return "Z"
        default:          return "key#\(keyCode)"
        }
    }
}

// ============================================================
// MARK: - 1b. Clipboard write seam (pure + seam)
//
//   This REPLACES the deleted `PasteboardStashing` /
//   `ClipboardStasher` / save-restore round-trip. There is NO snapshot
//   and NO restore: the user WANTS the resolved body left on the
//   clipboard. The only operation is "replace the clipboard's plain-text
//   contents with this string", and the test double can read it back so
//   the on-Enter write is headlessly verifiable.
// ============================================================

/// Minimal write-only seam over `NSPasteboard`. The palette's sole
/// pasteboard interaction. `readString()` exists ONLY so the harness can
/// assert what was written (and so the controller can no-op an
/// empty-body write) — it is never used to snapshot/restore.
public protocol ClipboardWriting: AnyObject, Sendable {
    /// Replace the clipboard's contents with a single plain-text payload.
    func writeString(_ s: String)
    /// Current plain-text payload (test read-back / empty-body guard).
    func readString() -> String?
}

/// In-memory test double for `ClipboardWriting`. Write fully replaces
/// the stored value (models `clearContents()` + `setString`).
public final class InMemoryClipboard: ClipboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    /// Number of writes performed (lets a test prove "wrote exactly once"
    /// / "never wrote" without a save/restore changeCount dance).
    public private(set) var writeCount = 0

    public init(initial: String? = nil) { _value = initial }

    public func writeString(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        _value = s
        writeCount += 1
    }

    public func readString() -> String? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}

/// Live adapter backed by `NSPasteboard.general`. PLAIN TEXT ONLY:
/// `clearContents()` then `setString(_, .string)` — the clipboard now
/// holds exactly the resolved command body. Nothing is snapshotted and
/// nothing is restored (by design — the user wants it on the clipboard).
public final class SystemClipboard: ClipboardWriting, @unchecked Sendable {
    private let pb: NSPasteboard
    public init(_ pb: NSPasteboard = .general) { self.pb = pb }

    public func writeString(_ s: String) {
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    public func readString() -> String? { pb.string(forType: .string) }
}

