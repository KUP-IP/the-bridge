// PasteboardHistoryModule.swift — NSPasteboard polling history with persistence
// NotionBridge · Modules
//
// PKT-765 (v2.2 · 3.3.1) — MAC UI extras Wave 2.
//
// Background subscriber polls NSPasteboard.general.changeCount every ~750ms;
// when the count advances and the pasteboard contains a string payload,
// captures a {text, timestamp, changeCount} entry into a rolling 50-entry
// buffer persisted to ~/Library/Application Support/The Bridge/pasteboard/history.json.
//
// Permissions: none. NSPasteboard read does not require any TCC grant in
// macOS 26 Tahoe (clipboard access is sandbox/profile-gated only).
//
// Lifetime: PasteboardHistoryStore.shared is a process-wide singleton.
// .start() is idempotent; called from `register` so the poller runs as soon
// as the module is wired into the router (server boot or test setup).

import Foundation
import AppKit
import MCP

public final class PasteboardHistoryStore: @unchecked Sendable {
    public static let shared = PasteboardHistoryStore()

    public struct Entry: Codable, Equatable, Sendable {
        public let text: String
        public let timestamp: Date
        public let changeCount: Int
    }

    public static let maxEntries: Int = 50
    public static let pollIntervalMs: Int = 750

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var lastChangeCount: Int = -1
    private var pollTimer: DispatchSourceTimer?
    private let storeURL: URL
    private let queue = DispatchQueue(label: "kup.solutions.the-bridge.pasteboard-history", qos: .utility)

    private init() {
        // PKT-1 v3.5: BridgePaths is the canonical home — lands under
        // ~/Library/Application Support/The Bridge/pasteboard/.
        let dir = (try? BridgePaths.ensureApplicationSupport(.pasteboard))
            ?? BridgePaths.applicationSupport(.pasteboard)
        self.storeURL = dir.appendingPathComponent("history.json")
        loadFromDisk()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let decoded = try? dec.decode([Entry].self, from: data) {
            lock.lock()
            entries = Array(decoded.prefix(Self.maxEntries))
            lock.unlock()
        }
    }

    /// Caller must hold `lock`. Snapshots entries and writes off-queue.
    private func persistLocked() {
        let snapshot = entries
        let url = storeURL
        queue.async {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100),
                       repeating: .milliseconds(Self.pollIntervalMs),
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        timer.resume()
        pollTimer = timer
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Public for tests + manual refresh on every `pasteboard_history` dispatch.
    /// Idempotent (no-op if changeCount unchanged).
    public func pollOnce() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount

        lock.lock()
        let unchanged = (cc == lastChangeCount)
        lock.unlock()
        if unchanged { return }

        // NSPasteboard reads are thread-safe; do them outside the lock to keep
        // critical-section time minimal.
        let text = pb.string(forType: .string)

        lock.lock()
        lastChangeCount = cc
        if let s = text, !s.isEmpty {
            let entry = Entry(text: s, timestamp: Date(), changeCount: cc)
            entries.insert(entry, at: 0)
            if entries.count > Self.maxEntries {
                entries = Array(entries.prefix(Self.maxEntries))
            }
            persistLocked()
        }
        lock.unlock()
    }

    public func snapshot(limit: Int) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let n = max(0, min(limit, entries.count))
        return Array(entries.prefix(n))
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Test/debug surface — wipes in-memory + on-disk history.
    public func reset() {
        lock.lock()
        entries.removeAll()
        lastChangeCount = -1
        lock.unlock()
        try? FileManager.default.removeItem(at: storeURL)
    }

    public var storeFileURL: URL { storeURL }
}

public enum PasteboardHistoryModule {
    public static let moduleName = "computer"

    private static func intParam(_ p: [String: Value], _ k: String, default fb: Int) -> Int {
        guard let v = p[k] else { return fb }
        switch v {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        default:             return fb
        }
    }
    private static func unwrap(_ a: Value) -> [String: Value] {
        if case .object(let d) = a { return d }
        return [:]
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func register(on router: ToolRouter) async {
        // Start the background poller as soon as the module is wired in.
        PasteboardHistoryStore.shared.start()

        await router.register(ToolRegistration(
            name: "pasteboard_history",
            module: moduleName,
            tier: .open,
            description: "Return the rolling pasteboard (clipboard) history captured by the bridge — up to the 50 most-recent string clips with timestamps and changeCount markers. Polling rate: 750ms (documented). Persists across bridge restarts under ~/Library/Application Support/The Bridge/pasteboard/history.json. No TCC permissions required.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type":        .string("integer"),
                        "description": .string("Max entries to return (1..50, default 50). Newest first.")
                    ])
                ])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                let limit = max(1, min(intParam(params, "limit", default: PasteboardHistoryStore.maxEntries),
                                       PasteboardHistoryStore.maxEntries))

                // Service a manual poll so on-demand callers see fresh content
                // even between scheduled ticks. Cheap (early-out on no change).
                PasteboardHistoryStore.shared.pollOnce()

                let entries = PasteboardHistoryStore.shared.snapshot(limit: limit)
                let rows: [Value] = entries.map { e in
                    .object([
                        "text":        .string(e.text),
                        "timestamp":   .string(iso.string(from: e.timestamp)),
                        "changeCount": .int(e.changeCount)
                    ])
                }
                return .object([
                    "entries":        .array(rows),
                    "count":          .int(entries.count),
                    "maxEntries":     .int(PasteboardHistoryStore.maxEntries),
                    "pollIntervalMs": .int(PasteboardHistoryStore.pollIntervalMs)
                ])
            }
        ))
    }
}
