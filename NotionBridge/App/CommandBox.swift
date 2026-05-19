// CommandBox.swift — cmd-sb (Commands palette: clipboard-only)
// NotionBridge · App
//
// The Commands palette is a global-hotkey → non-activating floating
// "command box" (the Alfred/Raycast pattern). On Enter it resolves the
// selected registry skill's page body and writes that Markdown to the
// system clipboard — and STOPS there. The user explicitly wants the body
// ON THE CLIPBOARD; they paste it themselves, wherever they want.
//
// The cmd-w1-spike paste-back subsystem (prior-app capture, reactivate,
// synthetic Cmd-V, clipboard save/restore round-trip, focus-restore +
// its timing policy) has been DELETED in full — the palette no longer
// touches another app, never synthesises keystrokes, and never
// save/restores the pasteboard. The single remaining pasteboard
// interaction is one `clearContents()+setString(.string)` write of the
// resolved body, behind the `ClipboardWriting` seam so it is headlessly
// asserted (write → read back) in the test harness.
//
// This file now owns only:
//
//   1. PURE, INJECTABLE LOGIC (unit-tested in the custom harness):
//      - HotkeyConfig            — Carbon RegisterEventHotKey config model
//      - ClipboardWriting        — protocol seam over NSPasteboard (write-only)
//      - InMemoryClipboard       — test double (write + read-back)
//      - SystemClipboard         — NSPasteboard.general adapter (replace contents)
//
//   2. GUI GLUE (structurally sound; needs manual smoke — NOT headless-faked):
//      - CommandBoxPanel         — NSPanel(.nonactivatingPanel)
//      - CommandBoxController     — Carbon hotkey + panel + fuzzy search +
//                                   the single clipboard write
//
// PERMISSION MODEL (why this is the low-risk design):
//   - Carbon `RegisterEventHotKey` is a HOT-KEY REGISTRATION, not an
//     event tap. It requires NO Input Monitoring and NO Accessibility
//     TCC grant — the WindowServer delivers a Carbon event only when the
//     exact combo is pressed.
//   - NSPasteboard write needs NO TCC grant (already proven by
//     PasteboardHistoryStore). With paste-back deleted there is no
//     CGEvent synthesis and therefore no Accessibility surface at all.

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

    /// The fixed default: ⌥⌘Space (Option+Command+Space). Chosen to avoid
    /// Spotlight (⌘Space) and the macOS dictation / emoji defaults. A
    /// real feature would make this user-configurable and conflict-checked.
    public static let spikeDefault = HotkeyConfig(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(cmdKey | optionKey)
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

    /// Human-readable combo, for logging / smoke output.
    public var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        if keyCode == UInt32(kVK_Space) { s += "Space" } else { s += "key#\(keyCode)" }
        return s
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

// ============================================================
// MARK: - 2. GUI GLUE — CommandBoxPanel + CommandBoxController
//   Structurally sound. NOT unit-tested headlessly (honest): a global
//   Carbon hot-key firing + a non-activating NSPanel receiving key
//   events both require a live WindowServer/loginwindow session. The
//   pure pieces above (and the clipboard write via the seam) ARE tested;
//   this shell wires them and is exercised by manual smoke.
// ============================================================

#if canImport(AppKit)

/// A borderless, non-activating floating panel that does not steal key
/// focus from the frontmost app when shown. `canBecomeKey` is true so
/// the text field inside can receive typing while the prior app stays
/// "active" from the user's perspective (the Alfred panel behaviour).
public final class CommandBoxPanel: NSPanel {
    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 44),
            // .nonactivatingPanel is the load-bearing flag: shows without
            // making this app the active app. .titled-less borderless.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    // A borderless panel returns false by default; we need true so the
    // embedded NSTextField can become first responder and receive typing.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

/// Controller: registers the Carbon hot-key, shows/hides the panel, runs
/// a live fuzzy search over the registry-backed command list as the user
/// types (delegated to the GUI-free `CommandPaletteCoordinator`), and on
/// Enter fetches the selected command's resolved body via the W2
/// `CommandsManager` (CONSUMED, not duplicated) then WRITES that body to
/// the clipboard. No prior-app capture, no reactivate, no Cmd-V, no
/// save/restore — the body is simply left on the clipboard for the user.
///
/// The fuzzy-search + body-fetch decision is the GUI-FREE
/// `CommandPaletteCoordinator` (unit-tested headlessly). This shell only
/// owns the AppKit glue (panel, text field, hot-key) — the parts that
/// genuinely require a WindowServer and are operator manual-smoke.
@MainActor
public final class CommandBoxController {
    private let hotkey: HotkeyConfig
    private let clipboard: ClipboardWriting
    /// The GUI-free search + W2-body-fetch core. Required — the palette
    /// always resolves the typed text as a fuzzy QUERY against the
    /// registry, fetches the matched skill's body, and writes it to the
    /// clipboard. A non-matching query writes NOTHING (never a guess).
    private let coordinator: CommandPaletteCoordinator

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var panel: CommandBoxPanel?
    private var textField: NSTextField?

    public private(set) var isRegistered = false
    public private(set) var isVisible = false

    public init(hotkey: HotkeyConfig = .spikeDefault,
                clipboard: ClipboardWriting = SystemClipboard(),
                coordinator: CommandPaletteCoordinator) {
        self.hotkey = hotkey
        self.clipboard = clipboard
        self.coordinator = coordinator
    }

    // MARK: Hot-key registration (Carbon — no Input Monitoring)

    /// Register the global hot-key. Refuses a modifier-less combo. Safe to
    /// call once; idempotent. Returns false on failure (e.g. combo taken).
    @discardableResult
    public func registerHotkey() -> Bool {
        guard hotkey.hasModifier else {
            print("[CommandBox] refusing modifier-less hot-key")
            return false
        }
        guard !isRegistered else { return true }

        // Install the application-level Carbon event handler for
        // kEventHotKeyPressed. The callback trampolines back to `self`.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID
                )
                if err == noErr, hkID.signature == HotkeyConfig.signature {
                    let ctrl = Unmanaged<CommandBoxController>
                        .fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in ctrl.handleHotkey() }
                }
                return noErr
            },
            1, &spec, selfPtr, &eventHandler
        )
        guard installStatus == noErr else {
            print("[CommandBox] InstallEventHandler failed: \(installStatus)")
            return false
        }

        let hkID = EventHotKeyID(signature: HotkeyConfig.signature, id: 1)
        let regStatus = RegisterEventHotKey(
            hotkey.keyCode, hotkey.carbonModifiers, hkID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard regStatus == noErr else {
            print("[CommandBox] RegisterEventHotKey failed: \(regStatus) (combo likely taken)")
            return false
        }

        isRegistered = true
        print("[CommandBox] registered global hot-key \(hotkey.displayString) (Carbon — no Input Monitoring)")
        return true
    }

    public func unregisterHotkey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
        isRegistered = false
    }

    // MARK: Show / commit

    private func handleHotkey() {
        if isVisible { hide(); return }
        show()
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Center-bottom of the main screen (Spotlight-ish placement).
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let size = panel.frame.size
            let origin = NSPoint(
                x: f.midX - size.width / 2,
                y: f.minY + f.height * 0.28
            )
            panel.setFrameOrigin(origin)
        }

        // orderFrontRegardless does NOT activate this app — the panel
        // appears over the (still-active) prior app.
        panel.orderFrontRegardless()
        panel.makeFirstResponder(textField)
        isVisible = true
    }

    private func makePanel() -> CommandBoxPanel {
        let panel = CommandBoxPanel()
        let field = NSTextField(frame: NSRect(x: 12, y: 6, width: 536, height: 32))
        field.placeholderString = "Type a command, press ⏎ to copy"
        field.font = .systemFont(ofSize: 18)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.target = self
        field.action = #selector(commitFromField(_:))
        let container = NSView(frame: panel.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.addSubview(field)
        panel.contentView = container
        self.textField = field
        return panel
    }

    @objc private func commitFromField(_ sender: NSTextField) {
        let query = sender.stringValue
        sender.stringValue = ""

        // The typed text is a fuzzy QUERY. Hide the panel, resolve the
        // body via the W2 CommandsManager, and write it to the clipboard.
        // `.notFound` writes NOTHING (never copy a guessed command).
        panel?.orderOut(nil)
        isVisible = false
        Task { @MainActor in
            let result = await self.coordinator.commit(query: query)
            self.applyCommit(result)
        }
    }

    /// Clipboard-only commit: on `.paste(body)` write the resolved body
    /// to the clipboard (replace contents — no save/restore). On
    /// `.notFound` / `.unavailable` write nothing (no guess, no
    /// destructive clobber). Public so the harness can drive this pure
    /// decision against an `InMemoryClipboard` with NO GUI (no panel, no
    /// hot-key) — the headlessly-verifiable core of the on-Enter behaviour.
    public func applyCommit(_ result: CommandPaletteCommitResult) {
        switch result {
        case .paste(let body):
            guard !body.isEmpty else { return }
            clipboard.writeString(body)
        case .notFound:
            // No command matched — do NOT copy a guess.
            break
        case .unavailable(_, let reason):
            print("[CommandBox] command body unavailable: \(reason)")
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }
}

#endif
