// VoiceMemoDiscovery.swift — locate Voice Memos recordings + idempotency manifest
// TheBridge · Modules · VoiceMemo

import Foundation

public enum VoiceMemoTranscriptSource: String, Sendable, Codable, Equatable {
    case sidecar
    case apple
    case parakeet
    case none
}

public struct VoiceMemoTranscriptMeta: Codable, Sendable, Equatable {
    public var source: VoiceMemoTranscriptSource
    public var extractedAt: String
    public var charCount: Int
    public var forced: Bool?

    public init(source: VoiceMemoTranscriptSource, extractedAt: String, charCount: Int, forced: Bool? = nil) {
        self.source = source
        self.extractedAt = extractedAt
        self.charCount = charCount
        self.forced = forced
    }
}

public struct VoiceMemoTranscriptResolution: Sendable, Equatable {
    public var text: String?
    public var source: VoiceMemoTranscriptSource

    public init(text: String?, source: VoiceMemoTranscriptSource) {
        self.text = text
        self.source = source
    }
}

public enum VoiceMemoDiscovery {

    /// Production search roots (best-effort — Apple moves containers across releases).
    public static func defaultRecordingRoots(home: URL = BridgePaths.homeRoot) -> [URL] {
        [
            home.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true),
            home.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true),
        ]
    }

    private static let audioExtensions: Set<String> = ["m4a", "qta", "caf", "wav"]

    /// List recordings under `roots`, newest first.
    public static func listRecordings(
        roots: [URL],
        transcriptLoader: @Sendable (URL) -> String? = { loadTranscriptSidecar(for: $0) }
    ) -> [VoiceMemoRecording] {
        let fm = FileManager.default
        var found: [VoiceMemoRecording] = []
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for url in entries {
                let ext = url.pathExtension.lowercased()
                guard audioExtensions.contains(ext) else { continue }
                let attrs = (try? url.resourceValues(forKeys: [.contentModificationDateKey])) ?? nil
                let mtime = attrs?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                let base = url.deletingPathExtension().lastPathComponent
                let id = stableId(for: url)
                let source = detectTranscriptSource(for: url)
                let transcript = transcriptLoader(url) ?? embeddedTranscriptPreview(for: url, source: source)
                found.append(VoiceMemoRecording(
                    id: id,
                    path: url.path,
                    title: humanizeFilename(base),
                    recordedAt: mtime,
                    transcript: transcript,
                    transcriptSource: source
                ))
            }
        }
        return found.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Read-only source detection for list views (does not write sidecars).
    public static func detectTranscriptSource(for audioURL: URL) -> VoiceMemoTranscriptSource {
        if let sidecar = loadTranscriptSidecar(for: audioURL) {
            _ = sidecar
            if let meta = loadTranscriptMeta(for: audioURL), meta.source != .none {
                return meta.source
            }
            return .sidecar
        }
        if BridgeDefaults.voiceMemoAppleTranscriptEffective,
           AppleVoiceMemoTranscriptExtractor.extract(from: audioURL) != nil {
            return .apple
        }
        return .none
    }

    private static func embeddedTranscriptPreview(for audioURL: URL, source: VoiceMemoTranscriptSource) -> String? {
        guard source == .apple else { return nil }
        return AppleVoiceMemoTranscriptExtractor.extract(from: audioURL)
    }

    /// Transcription ladder: sidecar cache → Apple tsrp → Parakeet fallback.
    public static func resolveTranscript(
        for audioURL: URL,
        forceParakeet: Bool = false
    ) async throws -> VoiceMemoTranscriptResolution {
        if !forceParakeet, let cached = loadTranscriptSidecar(for: audioURL) {
            let source = loadTranscriptMeta(for: audioURL)?.source ?? .sidecar
            return VoiceMemoTranscriptResolution(text: cached, source: source)
        }

        var appleText: String?
        if !forceParakeet, BridgeDefaults.voiceMemoAppleTranscriptEffective {
            appleText = AppleVoiceMemoTranscriptExtractor.extract(from: audioURL)
            if let appleText {
                let duration = AppleVoiceMemoTranscriptExtractor.audioDurationSeconds(at: audioURL) ?? 0
                let suspicious = appleTranscriptSuspiciouslyShort(text: appleText, audioDurationSec: duration)
                if !suspicious {
                    try writeTranscriptSidecar(for: audioURL, text: appleText, source: .apple)
                    return VoiceMemoTranscriptResolution(text: appleText, source: .apple)
                }
            }
        }

        if BridgeDefaults.voiceMemoParakeetTranscriptionEffective {
            do {
                let text = try await VoiceMemoTranscriber.transcribeFile(audioURL)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return VoiceMemoTranscriptResolution(text: nil, source: .none)
                }
                try writeTranscriptSidecar(for: audioURL, text: trimmed, source: .parakeet, forced: forceParakeet)
                return VoiceMemoTranscriptResolution(text: trimmed, source: .parakeet)
            } catch {
                // Parakeet unavailable or returned empty — fall through to Apple
                // fallback (if extracted) or nil below.
            }
        }

        if let appleText, !forceParakeet {
            try writeTranscriptSidecar(for: audioURL, text: appleText, source: .apple)
            return VoiceMemoTranscriptResolution(text: appleText, source: .apple)
        }

        return VoiceMemoTranscriptResolution(text: nil, source: .none)
    }

    /// Quality heuristic from MEMORY-HUB-EXECUTION-SPEC §3.
    public static func appleTranscriptSuspiciouslyShort(text: String, audioDurationSec: Double) -> Bool {
        let threshold = max(80.0, 0.05 * audioDurationSec * 15.0)
        return Double(text.count) < threshold
    }

    /// Sidecar transcript: `<audio-basename>.txt` adjacent to the audio file.
    public static func loadTranscriptSidecar(for audioURL: URL) -> String? {
        let sidecar = sidecarURL(for: audioURL)
        guard let data = try? Data(contentsOf: sidecar),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func sidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("txt")
    }

    public static func transcriptMetaURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("transcript.meta.json")
    }

    public static func loadTranscriptMeta(for audioURL: URL) -> VoiceMemoTranscriptMeta? {
        let url = transcriptMetaURL(for: audioURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VoiceMemoTranscriptMeta.self, from: data)
    }

    /// Persist transcript beside the audio with provenance metadata.
    public static func writeTranscriptSidecar(
        for audioURL: URL,
        text: String,
        source: VoiceMemoTranscriptSource = .sidecar,
        forced: Bool = false
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let sidecar = sidecarURL(for: audioURL)
        try trimmed.write(to: sidecar, atomically: true, encoding: .utf8)
        let meta = VoiceMemoTranscriptMeta(
            source: source,
            extractedAt: ISO8601DateFormatter().string(from: Date()),
            charCount: trimmed.count,
            forced: forced ? true : nil
        )
        let metaData = try JSONEncoder().encode(meta)
        try metaData.write(to: transcriptMetaURL(for: audioURL), options: .atomic)
    }

    public static func stableId(for url: URL) -> String {
        let path = url.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber,
           let mtime = attrs[.modificationDate] as? Date {
            return "\(url.lastPathComponent)-\(size.intValue)-\(Int(mtime.timeIntervalSince1970))"
        }
        return url.lastPathComponent
    }

    private static func humanizeFilename(_ base: String) -> String {
        base.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

// MARK: - Processed manifest

public struct VoiceMemoProcessedManifest: Codable, Sendable, Equatable {
    public var processed: [String: String]

    public init(processed: [String: String] = [:]) {
        self.processed = processed
    }
}

public enum VoiceMemoProcessedStore {
    public static var manifestURL: URL {
        BridgePaths.applicationSupport(.voiceMemos).appendingPathComponent("processed.json")
    }

    public static func load() -> VoiceMemoProcessedManifest {
        let url = manifestURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(VoiceMemoProcessedManifest.self, from: data) else {
            return VoiceMemoProcessedManifest()
        }
        return decoded
    }

    public static func save(_ manifest: VoiceMemoProcessedManifest) throws {
        let dir = manifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    public static func markProcessed(id: String, at date: Date = Date()) throws {
        var manifest = load()
        manifest.processed[id] = ISO8601DateFormatter().string(from: date)
        try save(manifest)
    }

    public static func isProcessed(id: String) -> Bool {
        load().processed[id] != nil
    }
}
