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
//      - CommandBoxController     — Carbon hotkey + panel + results table +
//                                   ↑/↓ selection + inline state messages +
//                                   the single clipboard write
//
// HONEST P2 GUI CEILING (NOT papered over): the global hot-key firing,
// the non-activating NSPanel receiving keystrokes, the NSTableView
// rendering the live results, the ↑/↓ key events reaching the panel, the
// confirmation-then-dismiss timer, and multi-monitor placement on a real
// WindowServer ALL require a live login session and are an explicit
// operator manual-smoke. The DECISION logic underneath each of those —
// the ranked results (`CommandPaletteCoordinator.search`), the ↑/↓
// selection state machine (`CommandPaletteSelection`), the commit→message
// mapping (`CommandPalettePresenter`), the active/unavailable status
// (`CommandsSettingsStatus`), and the screen-pick math
// (`CommandBoxController.placementOrigin`) — is PURE and 100%-green-tested.
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

    /// The original spike default: ⌥⌘Space (Option+Command+Space).
    /// RETAINED only so historical references / Codable fixtures stay
    /// valid — the SHIPPING default is `productionDefault` (⌃⌥⌘C). Chosen
    /// originally to avoid Spotlight (⌘Space) and macOS dictation.
    public static let spikeDefault = HotkeyConfig(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(cmdKey | optionKey)
    )

    /// The SHIPPING production default: ⌃⌥⌘C (Control+Option+Command+C).
    /// Carbon `kVK_ANSI_C` (8) + `controlKey | optionKey | cmdKey`.
    /// `hasModifier` is true so the controller will register it. The
    /// triple-modifier combo is collision-resistant (no default macOS or
    /// common-app binding owns ⌃⌥⌘C), and the in-Settings recorder
    /// (Change B) lets the operator rebind it live if it ever conflicts.
    public static let productionDefault = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_C),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
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
    ///          every app — `CommandBoxController.registerHotkey()` also
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
    /// letter row used by the shipping default (⌃⌥⌘C → "C"); unknown codes
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
public final class CommandBoxController: NSObject {
    /// The combo the controller registers. `var` (not `let`) so the
    /// in-Settings recorder can live-rebind without a relaunch via
    /// `rebind(to:)` — see Change B.
    private var hotkey: HotkeyConfig
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
    private var resultsTable: NSTableView?
    private var statusLabel: NSTextField?

    /// The current ranked rows backing the results table.
    private var results: [ScoredCommand] = []
    /// The PURE ↑/↓ selection state machine. The table only renders the
    /// index this yields — it owns no selection logic of its own.
    private var selection = CommandPaletteSelection()
    /// Generation token so a slow `coordinator.search` for stale text
    /// can't overwrite a newer query's results (last-typed wins).
    private var searchGeneration = 0
    /// Pending auto-dismiss work for a "Copied ‹name›" confirmation.
    private var dismissWorkItem: DispatchWorkItem?

    public private(set) var isRegistered = false
    public private(set) var isVisible = false

    /// The combo this controller currently registers (or last tried to).
    /// Read by the Settings status row + the live-rebind path so the
    /// displayed glyph always tracks the controller's real config.
    public var hotkeyConfig: HotkeyConfig { hotkey }

    // MARK: Pure placement (multi-monitor) — unit-tested headlessly

    /// The panel origin for a given target screen frame + panel size.
    /// PURE so the multi-monitor math is asserted without a WindowServer.
    /// Centred horizontally, ~28% up from the bottom of the visible frame
    /// (the Spotlight placement) — but on the screen the caller passes
    /// (active/key window's or the mouse's), NOT always `NSScreen.main`.
    public nonisolated static func placementOrigin(
        screenVisibleFrame f: CGRect,
        panelSize size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: f.midX - size.width / 2,
            y: f.minY + f.height * 0.28
        )
    }

    /// Pick the screen the panel should open on: the one containing the
    /// key window, else the one under the mouse, else `NSScreen.main`,
    /// else the first screen. PURE given the inputs so the selection
    /// policy is unit-tested without a live display arrangement.
    public nonisolated static func pickScreenFrame(
        screens: [CGRect],
        keyWindowFrame: CGRect?,
        mouseLocation: CGPoint,
        mainScreenFrame: CGRect?
    ) -> CGRect? {
        func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
            frame.contains(point)
        }
        if let kw = keyWindowFrame {
            let center = CGPoint(x: kw.midX, y: kw.midY)
            if let hit = screens.first(where: { contains($0, center) }) { return hit }
        }
        if let hit = screens.first(where: { contains($0, mouseLocation) }) { return hit }
        if let main = mainScreenFrame { return main }
        return screens.first
    }

    public init(hotkey: HotkeyConfig = .productionDefault,
                clipboard: ClipboardWriting = SystemClipboard(),
                coordinator: CommandPaletteCoordinator) {
        self.hotkey = hotkey
        self.clipboard = clipboard
        self.coordinator = coordinator
        super.init()
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

    /// Live-rebind to a new combo WITHOUT a relaunch (Change B). Uses the
    /// existing idempotent `unregisterHotkey()` + `registerHotkey()`
    /// path. On success the controller now owns the new combo. On FAILURE
    /// (the new combo is taken by another app) the prior working combo is
    /// restored and re-registered so the palette is never left dead — the
    /// caller surfaces the ⚠ and lets the user try another combo.
    ///
    /// Returns whether the NEW combo registered successfully.
    @discardableResult
    public func rebind(to newHotkey: HotkeyConfig) -> Bool {
        let previous = hotkey
        unregisterHotkey()
        hotkey = newHotkey
        if registerHotkey() {
            return true
        }
        // New combo failed — fall back to the prior working combo so the
        // palette keeps responding to the old shortcut (best-effort).
        hotkey = previous
        _ = registerHotkey()
        return false
    }

    // MARK: Show / commit

    private func handleHotkey() {
        if isVisible { hide(); return }
        show()
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Multi-monitor (P2.8): open on the screen containing the key
        // window, else the mouse, else main — NOT always NSScreen.main.
        // The screen-pick + origin math is the PURE, unit-tested
        // `pickScreenFrame` / `placementOrigin`; this is only the glue.
        let screenFrames = NSScreen.screens.map { $0.visibleFrame }
        if let target = Self.pickScreenFrame(
            screens: screenFrames,
            keyWindowFrame: NSApp.keyWindow?.frame,
            mouseLocation: NSEvent.mouseLocation,
            mainScreenFrame: NSScreen.main?.visibleFrame
        ) {
            panel.setFrameOrigin(
                Self.placementOrigin(screenVisibleFrame: target,
                                     panelSize: panel.frame.size)
            )
        }

        // Reset transient state for a fresh invocation.
        textField?.stringValue = ""
        clearStatus()
        refreshResults(for: "")

        // orderFrontRegardless does NOT activate this app — the panel
        // appears over the (still-active) prior app.
        panel.orderFrontRegardless()
        panel.makeFirstResponder(textField)
        isVisible = true
    }

    private func makePanel() -> CommandBoxPanel {
        // Taller panel: query field on top, a results list below it, and
        // a thin status line at the bottom.
        let width: CGFloat = 560
        let panel = CommandBoxPanel()
        panel.setContentSize(NSSize(width: width, height: 320))

        let field = QueryTextField(frame: NSRect(x: 12, y: 278, width: width - 24, height: 32))
        field.placeholderString = "Type a command, press \u{23CE} to copy"
        field.font = .systemFont(ofSize: 18)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.target = self
        field.action = #selector(commitFromField(_:))
        field.delegate = self
        field.onArrow = { [weak self] arrow in self?.handleArrow(arrow) }

        // Results table inside a scroll view.
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 32, width: width - 24, height: 238))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 30
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        col.width = width - 40
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(commitFromTable(_:))
        scroll.documentView = table

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 14, y: 7, width: width - 28, height: 18)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.isHidden = true

        let container = NSView(frame: panel.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.addSubview(field)
        container.addSubview(scroll)
        container.addSubview(status)
        panel.contentView = container

        self.textField = field
        self.resultsTable = table
        self.statusLabel = status
        return panel
    }

    // MARK: Live results (driven by the GUI-free coordinator)

    /// Re-rank the results for `query` via the coordinator, re-seat the
    /// PURE selection model (top row preselected, stale index clamped),
    /// and reload the table. Generation-guarded so a slow stale search
    /// can't clobber a newer one.
    private func refreshResults(for query: String) {
        searchGeneration &+= 1
        let gen = searchGeneration
        Task { @MainActor in
            let ranked = await self.coordinator.search(query)
            guard gen == self.searchGeneration else { return }
            self.results = ranked
            self.selection.updateResultCount(ranked.count)
            self.resultsTable?.reloadData()
            self.syncTableSelection()
            if ranked.isEmpty {
                self.showStatus(CommandPalettePresenter.emptyRegistryMessage,
                                warning: false)
            } else {
                self.clearStatus()
            }
        }
    }

    /// Push the pure selection index onto the AppKit table.
    private func syncTableSelection() {
        guard let table = resultsTable else { return }
        if let i = selection.selectedIndex, i < results.count {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            table.scrollRowToVisible(i)
        } else {
            table.deselectAll(nil)
        }
    }

    /// ↑/↓ from the text field: advance the PURE selection model and
    /// mirror it onto the table. No wrap (clamped) — matches Spotlight.
    private func handleArrow(_ arrow: CommandPaletteArrow) {
        selection.move(arrow)
        syncTableSelection()
    }

    private func showStatus(_ message: String, warning: Bool) {
        guard let label = statusLabel else { return }
        label.stringValue = message
        label.textColor = warning ? .systemRed : .secondaryLabelColor
        label.isHidden = message.isEmpty
    }

    private func clearStatus() {
        statusLabel?.stringValue = ""
        statusLabel?.isHidden = true
    }

    @objc private func commitFromTable(_ sender: Any?) {
        commitCurrent()
    }

    @objc private func commitFromField(_ sender: NSTextField) {
        commitCurrent()
    }

    /// The unified Enter path. ⏎ commits the SELECTED descriptor; if
    /// nothing is explicitly selected it falls back to the best-match of
    /// the raw query (the original behaviour). Empty query ⇒ pure no-op.
    /// The commit→message + stays-open decision is the PURE
    /// `CommandPalettePresenter` (unit-tested); this only renders it.
    private func commitCurrent() {
        let query = textField?.stringValue ?? ""
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty query ⏎ → no-op (panel stays, clipboard untouched).
        if trimmed.isEmpty {
            return
        }

        let selected: CommandDescriptor? = {
            if let i = selection.selectedIndex, i < results.count {
                return results[i].descriptor
            }
            return nil
        }()
        let confirmName = selected?.name ?? trimmed

        Task { @MainActor in
            let result: CommandPaletteCommitResult
            if let descriptor = selected {
                result = await self.coordinator.commit(descriptor)
            } else {
                result = await self.coordinator.commit(query: query)
            }
            // Clipboard write (or deliberate no-op) — UNCHANGED public API.
            self.applyCommit(result)

            // Pure presentation: exact message + stays-open + whether to
            // flash a confirmation then auto-dismiss.
            let p = CommandPalettePresenter.present(result, name: confirmName)
            if p.isConfirmation {
                self.showStatus(p.message, warning: false)
                self.scheduleConfirmationDismiss()
            } else if !p.message.isEmpty {
                // .notFound / .unavailable → panel stays open (p.staysOpen
                // is true for both) so the user can correct the query.
                self.showStatus(p.message, warning: true)
            }
        }
    }

    /// Flash the "Copied ‹name›" confirmation, then auto-dismiss after
    /// the pure-defined delay. Any earlier pending dismiss is cancelled.
    private func scheduleConfirmationDismiss() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(CommandPalettePresenter.confirmationDismissMillis),
            execute: work
        )
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
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Esc from the panel — dismiss without any clipboard write.
    fileprivate func dismissOnEscape() {
        hide()
    }

    /// Live search as the user types. Driven by the text field's
    /// `controlTextDidChange`.
    fileprivate func queryDidChange(_ query: String) {
        clearStatus()
        refreshResults(for: query)
    }
}

// MARK: - Text-field key handling (↑/↓/Esc + live search)

extension CommandBoxController: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        queryDidChange(field.stringValue)
    }

    /// Intercept ↑/↓ (move selection) and Esc (dismiss) so they drive
    /// the PURE selection model rather than editing the text field.
    public func control(_ control: NSControl,
                        textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            handleArrow(.up)
            return true
        case #selector(NSResponder.moveDown(_:)):
            handleArrow(.down)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissOnEscape()
            return true
        default:
            return false
        }
    }
}

// MARK: - Results table data source / delegate

extension CommandBoxController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    public func tableView(_ tableView: NSTableView,
                           viewFor tableColumn: NSTableColumn?,
                           row: Int) -> NSView? {
        guard row < results.count else { return nil }
        let d = results[row].descriptor
        let id = NSUserInterfaceItemIdentifier("CmdCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? {
                let tf = NSTextField(labelWithString: "")
                tf.identifier = id
                tf.font = .systemFont(ofSize: 15)
                tf.lineBreakMode = .byTruncatingTail
                return tf
            }()
        cell.stringValue = d.name
        return cell
    }

    /// A mouse click in the table is a user selection — mirror it back
    /// into the PURE model so a subsequent ⏎ commits the clicked row.
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return }
        selection.updateResultCount(results.count)
        // O(1) direct seat (keeps CommandPaletteSelection the single
        // source of truth) so a subsequent ⏎ commits the clicked row.
        selection.select(index: row)
    }
}

/// An `NSTextField` that surfaces ↑/↓ to the controller even though the
/// field editor would otherwise consume them. The Esc/arrow routing is
/// handled via the delegate's `doCommandBy:`; this hook is a structural
/// belt-and-suspenders kept minimal (the DECISION — what an arrow does —
/// is the pure `CommandPaletteSelection`, unit-tested).
final class QueryTextField: NSTextField {
    var onArrow: ((CommandPaletteArrow) -> Void)?
}

#endif
