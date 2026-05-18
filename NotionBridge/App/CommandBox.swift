// CommandBox.swift — Feasibility spike (cmd-w1-spike)
// NotionBridge · App
//
// SPIKE GOAL: prove a global-hotkey → non-activating floating "command box"
// → paste-back-into-prior-app architecture (the Alfred/Raycast pattern),
// replacing the explicitly-rejected CGEventTap keylogger design.
//
// This file is intentionally split into:
//
//   1. PURE, INJECTABLE LOGIC (unit-tested in the custom harness):
//      - HotkeyConfig            — Carbon RegisterEventHotKey config model
//      - PasteboardStashing      — protocol seam over NSPasteboard
//      - InMemoryPasteboard      — test double
//      - ClipboardStasher        — save → set(plain text) → restore round-trip
//      - FrontmostAppProviding   — protocol seam over NSWorkspace
//      - PriorAppCapture         — capture-on-show / reactivate-on-commit model
//      - CommandBoxParameters    — paste-format + restore-timing policy
//
//   2. GUI GLUE (structurally sound; needs manual smoke — NOT headless-faked):
//      - CommandBoxController    — NSPanel(.nonactivatingPanel) + Carbon hotkey
//
// PERMISSION MODEL (why this is the low-risk design):
//   - Carbon `RegisterEventHotKey` is a HOT-KEY REGISTRATION, not an event
//     tap. It requires NO Input Monitoring and NO Accessibility TCC grant —
//     the WindowServer delivers a Carbon event only when the exact combo is
//     pressed. This is fundamentally different from CGEventTap (the rejected
//     keylogger), which sees every keystroke and needs Input Monitoring.
//   - The paste-back Cmd-V synthesis reuses the SAME CGEvent primitive
//     already shipping in SyntheticInputModule (Accessibility-gated). That
//     gate is pre-existing and unchanged by this spike.
//   - NSPasteboard read/write needs NO TCC grant (already proven by
//     PasteboardHistoryStore).

import Foundation
import AppKit
import CoreGraphics
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

    /// The spike's fixed default: ⌥⌘Space (Option+Command+Space).
    /// Chosen to avoid Spotlight (⌘Space) and the macOS dictation /
    /// emoji defaults. A real feature would make this user-configurable
    /// and conflict-checked; out of scope for the spike.
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

    /// Human-readable combo, for the spike's logging/smoke output.
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
// MARK: - 1b. Pasteboard stashing (pure + seam)
// ============================================================

/// Minimal seam over the parts of `NSPasteboard` the stash logic touches.
/// Lets the round-trip be unit-tested with an in-memory double — no GUI,
/// no real system pasteboard mutation in tests.
public protocol PasteboardStashing: AnyObject {
    var changeCount: Int { get }
    /// Snapshot the current plain-text payload (nil if non-text/empty).
    func readString() -> String?
    /// Clear + write a single plain-text payload. Returns the new changeCount.
    @discardableResult func writeString(_ s: String) -> Int
    /// Restore a previously snapshotted plain-text payload (or clear if nil).
    func restore(_ s: String?)
}

/// In-memory test double for `PasteboardStashing`.
public final class InMemoryPasteboard: PasteboardStashing, @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    private var _change = 0

    public init(initial: String? = nil) { _value = initial }

    public var changeCount: Int { lock.lock(); defer { lock.unlock() }; return _change }

    public func readString() -> String? { lock.lock(); defer { lock.unlock() }; return _value }

    @discardableResult
    public func writeString(_ s: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        _value = s
        _change += 1
        return _change
    }

    public func restore(_ s: String?) {
        lock.lock(); defer { lock.unlock() }
        _value = s
        _change += 1
    }
}

/// Live adapter backed by `NSPasteboard.general`. PLAIN TEXT ONLY by
/// design: we only ever snapshot/restore `.string`. Rich content (RTF,
/// files, images) is intentionally NOT preserved — restoring arbitrary
/// declared types is a known footgun (promised/lazy data, file
/// promises) and out of scope for the spike. Documented as a surviving
/// risk in the spike report.
public final class SystemPasteboard: PasteboardStashing, @unchecked Sendable {
    private let pb: NSPasteboard
    public init(_ pb: NSPasteboard = .general) { self.pb = pb }

    public var changeCount: Int { pb.changeCount }

    public func readString() -> String? { pb.string(forType: .string) }

    @discardableResult
    public func writeString(_ s: String) -> Int {
        pb.clearContents()
        pb.setString(s, forType: .string)
        return pb.changeCount
    }

    public func restore(_ s: String?) {
        pb.clearContents()
        if let s { pb.setString(s, forType: .string) }
    }
}

/// Encapsulates the save → set → (paste happens) → restore round-trip.
/// Pure and synchronous; the GUI layer drives the actual Cmd-V + the
/// post-paste delay. `commit` returns a `RestoreToken` the caller invokes
/// after the paste has been delivered.
public struct ClipboardStasher {
    private let pb: PasteboardStashing

    public init(_ pb: PasteboardStashing) { self.pb = pb }

    /// Opaque restore handle — carries the snapshot so the caller can
    /// restore exactly what was there, after the paste lands.
    public struct RestoreToken {
        fileprivate let saved: String?
        fileprivate let pb: PasteboardStashing
        /// changeCount immediately AFTER we wrote our command text.
        public let postWriteChangeCount: Int

        /// Restore the user's original clipboard. Guarded: if something
        /// else wrote to the pasteboard between our set and now (count
        /// advanced past what we wrote), we DON'T clobber it — the user
        /// or another app intentionally changed it.
        public func restore() {
            if pb.changeCount == postWriteChangeCount {
                pb.restore(saved)
            }
            // else: stale — a newer write wins, do nothing.
        }

        /// Unconditional restore (used by the simplest timing policy /
        /// when the guard is not desired). Exposed for the spike tests.
        public func restoreUnconditionally() { pb.restore(saved) }
    }

    /// Snapshot the current plain-text clipboard, then overwrite it with
    /// `text` (plain text). Returns the token used to restore later.
    public func stash(_ text: String) -> RestoreToken {
        let saved = pb.readString()
        let newCount = pb.writeString(text)
        return RestoreToken(saved: saved, pb: pb, postWriteChangeCount: newCount)
    }
}

// ============================================================
// MARK: - 1c. Prior-app capture (pure + seam)
// ============================================================

/// Identifies the app to return focus to. Kept minimal/value-typed so the
/// capture/return decision is testable without a real `NSRunningApplication`.
public struct PriorApp: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t
    public init(bundleIdentifier: String?, processIdentifier: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

/// Seam over `NSWorkspace.shared.frontmostApplication` + activation.
public protocol FrontmostAppProviding: AnyObject {
    func currentFrontmost() -> PriorApp?
    /// Reactivate the captured app. Returns false if it can't (gone).
    func activate(_ app: PriorApp) -> Bool
}

/// The capture/return model. `capture()` is called just BEFORE the panel
/// is shown (records who was frontmost — which is still us-or-them since
/// a non-activating panel doesn't steal activation, but recording it is
/// the robust contract). `returnFocus()` is called on commit/cancel.
public final class PriorAppCapture {
    private let provider: FrontmostAppProviding
    private var captured: PriorApp?
    /// Bundle id of THIS app — never "return focus" to ourselves.
    private let selfBundleID: String?

    public init(provider: FrontmostAppProviding, selfBundleID: String?) {
        self.provider = provider
        self.selfBundleID = selfBundleID
    }

    public var capturedApp: PriorApp? { captured }

    /// Record the frontmost app, ignoring ourselves. Returns what was
    /// captured (nil if frontmost was us or nothing).
    @discardableResult
    public func capture() -> PriorApp? {
        guard let front = provider.currentFrontmost() else { captured = nil; return nil }
        if let sb = selfBundleID, front.bundleIdentifier == sb {
            // Frontmost is us (e.g. Settings window open) — nothing to
            // return to. A non-activating panel is the common case where
            // this DOESN'T happen, but guard anyway.
            captured = nil
            return nil
        }
        captured = front
        return front
    }

    /// Reactivate the captured app. No-op (returns false) if nothing was
    /// captured or the app vanished.
    @discardableResult
    public func returnFocus() -> Bool {
        guard let app = captured else { return false }
        return provider.activate(app)
    }

    public func reset() { captured = nil }
}

// ============================================================
// MARK: - 1d. Command-box parameters (pure policy)
// ============================================================

/// Tunable, testable policy for the paste-back sequence. The exact
/// numbers are spike defaults grounded in the Alfred/Raycast pattern;
/// a real feature would empirically tune them.
public struct CommandBoxParameters: Equatable, Sendable {
    /// Delay AFTER reactivating the prior app, BEFORE synthesizing Cmd-V.
    /// The reactivated app needs a beat to become key and route the
    /// keystroke to its focused field.
    public let reactivateToPasteDelayMs: Int
    /// Delay AFTER Cmd-V, BEFORE restoring the user's original clipboard.
    /// Must outlast the target app's async paste read. Too short = the
    /// app pastes the RESTORED (old) content; this is the single most
    /// fragile timing in the design (flagged as a surviving risk).
    public let pasteToRestoreDelayMs: Int
    /// Always plain text. Encodes deliverable #3's explicit "PLAIN TEXT
    /// (.string)" requirement as a checked invariant, not a comment.
    public let pasteFormatIsPlainTextOnly: Bool

    public init(reactivateToPasteDelayMs: Int = 60,
                pasteToRestoreDelayMs: Int = 250,
                pasteFormatIsPlainTextOnly: Bool = true) {
        self.reactivateToPasteDelayMs = reactivateToPasteDelayMs
        self.pasteToRestoreDelayMs = pasteToRestoreDelayMs
        self.pasteFormatIsPlainTextOnly = pasteFormatIsPlainTextOnly
    }

    public static let spikeDefault = CommandBoxParameters()

    /// Validate the policy is self-consistent for the paste-back pattern.
    public var isValid: Bool {
        reactivateToPasteDelayMs >= 0
            && pasteToRestoreDelayMs > reactivateToPasteDelayMs
            && pasteFormatIsPlainTextOnly
    }
}

// ============================================================
// MARK: - 1e. Cmd-V synthesis (pure construction, no posting in tests)
// ============================================================

/// Builds the Cmd-V key-down/key-up CGEvent pair. Construction is pure
/// and testable (we assert the events carry the right keyCode + the
/// .maskCommand flag); ACTUAL posting to `.cghidEventTap` is a GUI-time
/// side effect, kept out of the unit path.
public enum PasteKeystroke {
    /// vk for 'V'.
    public static let vKeyCode = CGKeyCode(kVK_ANSI_V)

    /// Returns (keyDown, keyUp) Cmd-V events, or nil if the event source
    /// can't be created (sandbox / no WindowServer in CI).
    public static func makeCommandVEvents() -> (down: CGEvent, up: CGEvent)? {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return nil }
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false)
        else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return (down, up)
    }

    /// Post a constructed pair to the HID tap. Side-effecting; GUI-only.
    public static func post(_ pair: (down: CGEvent, up: CGEvent)) {
        pair.down.post(tap: .cghidEventTap)
        pair.up.post(tap: .cghidEventTap)
    }
}

// ============================================================
// MARK: - 2. GUI GLUE — CommandBoxController
//   Structurally sound. NOT unit-tested headlessly (honest): a global
//   Carbon hot-key firing + a non-activating NSPanel receiving key
//   events both require a live WindowServer/loginwindow session and a
//   real frontmost app. The pure pieces above ARE tested; this shell
//   wires them and is exercised by manual smoke.
// ============================================================

#if canImport(AppKit)

/// Live `FrontmostAppProviding` over `NSWorkspace`.
public final class WorkspaceFrontmostProvider: FrontmostAppProviding {
    public init() {}

    public func currentFrontmost() -> PriorApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return PriorApp(bundleIdentifier: app.bundleIdentifier,
                        processIdentifier: app.processIdentifier)
    }

    public func activate(_ app: PriorApp) -> Bool {
        let running = NSRunningApplication(processIdentifier: app.processIdentifier)
        guard let running else { return false }
        // .activate on macOS 14+ — no deprecated options needed.
        return running.activate()
    }
}

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

/// W3 controller: registers the Carbon hot-key, shows/hides the panel,
/// runs a live fuzzy search over the cached command list as the user
/// types, and on Enter fetches the selected command's resolved body via
/// the W2 `CommandsManager` (CONSUMED, not duplicated) then runs the
/// spike's capture → reactivate → stash → Cmd-V → restore paste-back
/// using the PURE units above.
///
/// The fuzzy-search + body-fetch decision is delegated to the GUI-FREE
/// `CommandPaletteCoordinator` (unit-tested headlessly). This shell only
/// owns the AppKit glue (panel, text field, hot-key) — the parts that
/// genuinely require a WindowServer and are operator manual-smoke.
@MainActor
public final class CommandBoxController {
    private let hotkey: HotkeyConfig
    private let params: CommandBoxParameters
    private let capture: PriorAppCapture
    private let stasher: ClipboardStasher
    /// W3: the GUI-free search + W2-body-fetch core. `nil` ⇒ the spike's
    /// original "paste exactly what was typed" behaviour (preserved so the
    /// imported spike contract is unbroken); non-nil ⇒ typed text is a
    /// fuzzy QUERY resolved to a command body before paste.
    private let coordinator: CommandPaletteCoordinator?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var panel: CommandBoxPanel?
    private var textField: NSTextField?

    public private(set) var isRegistered = false
    public private(set) var isVisible = false

    public init(hotkey: HotkeyConfig = .spikeDefault,
                params: CommandBoxParameters = .spikeDefault,
                frontmost: FrontmostAppProviding = WorkspaceFrontmostProvider(),
                pasteboard: PasteboardStashing = SystemPasteboard(),
                coordinator: CommandPaletteCoordinator? = nil) {
        self.hotkey = hotkey
        self.params = params
        self.capture = PriorAppCapture(
            provider: frontmost,
            selfBundleID: Bundle.main.bundleIdentifier
        )
        self.stasher = ClipboardStasher(pasteboard)
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
        if isVisible { hide(commit: false); return }
        show()
    }

    private func show() {
        // 1. Record who was frontmost BEFORE we show anything.
        capture.capture()

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
        field.placeholderString = "Type a command, press ⏎"
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

        guard let coordinator else {
            // No W3 coordinator wired → spike behaviour: paste the typed
            // text verbatim (imported-contract preservation).
            hide(commit: true, text: query)
            return
        }

        // W3: the typed text is a fuzzy QUERY. Hide the panel immediately
        // (so it doesn't steal the paste target's focus during the async
        // fetch), reactivate the prior app, then resolve the body via the
        // W2 CommandsManager and paste it. `.notFound` does NOT paste.
        panel?.orderOut(nil)
        isVisible = false
        Task { @MainActor in
            let result = await coordinator.commit(query: query)
            switch result {
            case .paste(let body):
                self.pasteResolvedBody(body)
            case .notFound:
                // No command matched — do NOT paste a guess. Drop the
                // captured prior app; the user can re-invoke and retype.
                self.capture.reset()
            case .unavailable(_, let reason):
                print("[CommandBox] command body unavailable: \(reason)")
                self.capture.reset()
            }
        }
    }

    /// W3 paste-back of an already-resolved command body. Reuses the
    /// spike's tested capture → reactivate → stash → Cmd-V → restore
    /// units verbatim — only the source of `text` differs (a fetched
    /// command body instead of the literally-typed string).
    private func pasteResolvedBody(_ body: String) {
        guard !body.isEmpty else { capture.reset(); return }

        let reactivated = capture.returnFocus()
        guard reactivated else {
            print("[CommandBox] prior app gone — not pasting")
            capture.reset()
            return
        }

        let token = stasher.stash(body)
        let reMs = params.reactivateToPasteDelayMs
        let restoreMs = params.pasteToRestoreDelayMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(reMs)) {
            if let pair = PasteKeystroke.makeCommandVEvents() {
                PasteKeystroke.post(pair)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(restoreMs)) {
                token.restore()
                self.capture.reset()
            }
        }
    }

    /// The paste-back sequence (deliverable #3). Ordering and the two
    /// delays come straight from `CommandBoxParameters` (tested policy).
    private func hide(commit: Bool, text: String = "") {
        panel?.orderOut(nil)
        isVisible = false

        guard commit, !text.isEmpty else { capture.reset(); return }

        // Reactivate the previously-frontmost app.
        let reactivated = capture.returnFocus()
        guard reactivated else {
            print("[CommandBox] prior app gone — not pasting")
            capture.reset()
            return
        }

        // Stash user's clipboard + write our command text (PLAIN TEXT).
        let token = stasher.stash(text)

        // After the app becomes key, synthesize Cmd-V, then restore.
        let reMs = params.reactivateToPasteDelayMs
        let restoreMs = params.pasteToRestoreDelayMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(reMs)) {
            if let pair = PasteKeystroke.makeCommandVEvents() {
                PasteKeystroke.post(pair)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(restoreMs)) {
                token.restore()        // guarded: won't clobber a newer write
                self.capture.reset()
            }
        }
    }
}

#endif
