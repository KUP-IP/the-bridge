// ScreenRecording.swift – PKT-356: Screen Recording Tools
// NotionBridge · Modules
//
// Extension of ScreenModule with 2 recording tools:
//   screen_record_start (notify), screen_record_stop (notify).
// Uses SCStream with SCStreamOutput delegate writing to AVAssetWriter.
// Recording state managed by actor-isolated RecordingManager.
// Files written to <configuredDir>/nb-screen-<timestamp>.mp4 (default ~/Desktop, fallback /tmp).

import MCP
import ScreenCaptureKit
import CoreMedia
import AVFoundation
import os.log

private let recLog = Logger(subsystem: "kup.solutions.notion-bridge", category: "ScreenRecording")

// MARK: - ScreenModule Recording Extension

extension ScreenModule {

    /// Register screen recording tools on the given router.
    public static func registerRecording(on router: ToolRouter) async {

        // MARK: screen_record_start – Notify (write)
        await router.register(ToolRegistration(
            name: "screen_record_start",
            module: moduleName,
            tier: .notify,
            description: "Start a screen recording (60s default, 300s cap). Returns the target filePath immediately. Only one active at a time; end with screen_record_stop.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "safetyCap": .object([
                        "type": .string("integer"),
                        "description": .string("Max recording duration in seconds (default: 60, max: 300). Recording auto-stops after this.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                var cap: TimeInterval = 60
                if case .int(let c) = args["safetyCap"] { cap = min(TimeInterval(c), 300) }
                else if case .double(let c) = args["safetyCap"] { cap = min(c, 300) }

                do {
                    let result = try await RecordingManager.shared.start(safetyCap: cap)
                    var response: [String: Value] = [
                        "status":          .string("recording"),
                        "filePath":        .string(result.path),
                        "width":           .int(result.width),
                        "height":          .int(result.height),
                        "safetyCapSeconds": .int(Int(cap))
                    ]
                    if result.isFallback {
                        response["warning"] = .string("Configured output directory is invalid or not writable — fell back to /tmp")
                    }
                    return .object(response)
                } catch let error as RecordingError {
                    return error.toResponse()
                } catch {
                    return .object([
                        "error":   .string("recording_start_failed"),
                        "message": .string("Failed to start recording: \(error.localizedDescription)")
                    ])
                }
            }
        ))

        // MARK: screen_record_stop – Notify (write)
        await router.register(ToolRegistration(
            name: "screen_record_stop",
            module: moduleName,
            tier: .notify,
            description: "Stop the active screen recording and return final filePath, duration, and size.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                do {
                    let result = try await RecordingManager.shared.stop()
                    return .object([
                        "filePath":        .string(result.path),
                        "durationSeconds": .double((result.duration * 100).rounded() / 100),
                        "bytes":           .int(Int(result.bytes))
                    ])
                } catch let error as RecordingError {
                    return error.toResponse()
                } catch {
                    return .object([
                        "error":   .string("recording_stop_failed"),
                        "message": .string("Failed to stop recording: \(error.localizedDescription)")
                    ])
                }
            }
        ))
    }
}

// MARK: - Recording Errors

/// Structured error types for screen recording operations.
private enum RecordingError: Error {
    case screenRecordingDenied
    case noDisplays
    case recordingAlreadyActive
    case noActiveRecording
    case writerSetupFailed(String)
    case noFramesCaptured
    case finalizationFailed(String)

    func toResponse() -> Value {
        switch self {
        case .screenRecordingDenied:
            return .object([
                "error":   .string("screen_recording_denied"),
                "message": .string("Screen Recording permission not granted. Open System Settings > Privacy & Security > Screen Recording and enable NotionBridge.")
            ])
        case .noDisplays:
            return .object([
                "error":   .string("no_displays"),
                "message": .string("No capturable displays found.")
            ])
        case .recordingAlreadyActive:
            return .object([
                "error":   .string("recording_already_active"),
                "message": .string("A screen recording is already in progress. Stop it first with screen_record_stop.")
            ])
        case .noActiveRecording:
            return .object([
                "error":   .string("no_active_recording"),
                "message": .string("No screen recording is currently active.")
            ])
        case .writerSetupFailed(let detail):
            return .object([
                "error":   .string("writer_setup_failed"),
                "message": .string("AVAssetWriter setup failed: \(detail)")
            ])
        case .noFramesCaptured:
            return .object([
                "error":   .string("no_frames_captured"),
                "message": .string("Recording stopped but no video frames were captured. The output file has been removed.")
            ])
        case .finalizationFailed(let detail):
            return .object([
                "error":   .string("finalization_failed"),
                "message": .string("AVAssetWriter finalization failed: \(detail). The output file has been removed.")
            ])
        }
    }
}

// MARK: - Recording Delegate

/// SCStreamOutput delegate that receives sample buffers and writes them to AVAssetWriter.
/// Thread safety: uses NSLock for the session-start flag and frame counter (delegate runs on a GCD queue).
private class RecordingDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    let writerInput: AVAssetWriterInput
    let writer: AVAssetWriter
    private var sessionStarted = false
    private var _framesWritten: Int = 0
    private var _appendFailures: Int = 0
    private var _skippedFrames: Int = 0
    private let lock = NSLock()

    /// Thread-safe count of frames successfully appended to the writer input.
    var framesWritten: Int {
        lock.lock()
        defer { lock.unlock() }
        return _framesWritten
    }

    /// Thread-safe count of append failures.
    var appendFailures: Int {
        lock.lock()
        defer { lock.unlock() }
        return _appendFailures
    }

    /// Thread-safe count of skipped (non-complete) frames.
    var skippedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return _skippedFrames
    }

    init(writerInput: AVAssetWriterInput, writer: AVAssetWriter) {
        self.writerInput = writerInput
        self.writer = writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // ── FIX: Check SCStream frame status ──────────────────────────────
        // SCStream delivers non-video frames (idle, blank, suspended, started, stopped)
        // that do NOT contain valid pixel data. Appending these to AVAssetWriter
        // causes the writer to transition to .failed state. Only append .complete frames.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int {
            if statusRaw != SCFrameStatus.complete.rawValue {
                lock.lock()
                let skipCount = _skippedFrames
                _skippedFrames += 1
                lock.unlock()
                if skipCount == 0 {
                    recLog.info("Skipping first non-complete frame: status=\(statusRaw, privacy: .public)")
                }
                return
            }
        }

        lock.lock()
        let frameNum = _framesWritten
        if !sessionStarted {
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
                let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
                let fourCC = String(format: "%c%c%c%c",
                    (mediaSubType >> 24) & 0xFF,
                    (mediaSubType >> 16) & 0xFF,
                    (mediaSubType >> 8) & 0xFF,
                    mediaSubType & 0xFF)
                recLog.info("First frame: pixelFormat=\(fourCC, privacy: .public) dims=\(dims.width)x\(dims.height) pts=\(ts.seconds, privacy: .public)s writerStatus=\(self.writer.status.rawValue)")
            }
            writer.startSession(atSourceTime: ts)
            sessionStarted = true
        }
        lock.unlock()

        // Check writer health before appending
        guard writer.status == .writing else {
            lock.lock()
            if _appendFailures == 0 {
                recLog.error("Writer NOT in .writing state at frame \(frameNum): status=\(self.writer.status.rawValue) error=\(self.writer.error?.localizedDescription ?? "nil", privacy: .public)")
            }
            _appendFailures += 1
            lock.unlock()
            return
        }

        guard writerInput.isReadyForMoreMediaData else { return }
        let ok = writerInput.append(sampleBuffer)

        lock.lock()
        if ok {
            _framesWritten += 1
            if _framesWritten == 1 {
                recLog.info("First frame appended OK. writerStatus=\(self.writer.status.rawValue)")
            }
        } else {
            _appendFailures += 1
            if _appendFailures <= 3 {
                recLog.error("Append FAILED at frame \(frameNum). writerStatus=\(self.writer.status.rawValue) error=\(self.writer.error?.localizedDescription ?? "nil", privacy: .public)")
            }
        }
        lock.unlock()
    }
}

// MARK: - Recording Manager Actor

/// Actor-isolated manager ensuring only one recording session at a time.
/// Handles SCStream lifecycle, AVAssetWriter pipeline, and safety-cap auto-stop.
private actor RecordingManager {
    static let shared = RecordingManager()

    struct ActiveRecording {
        let stream: SCStream
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let delegate: RecordingDelegate
        let outputPath: String
        let startTime: Date
        var safetyTask: Task<Void, Never>?
    }

    private var recording: ActiveRecording?

    var isRecording: Bool { recording != nil }

    /// Start a new screen recording. Returns (filePath, width, height).
    func start(safetyCap: TimeInterval) async throws -> (path: String, width: Int, height: Int, isFallback: Bool) {
        guard recording == nil else {
            throw RecordingError.recordingAlreadyActive
        }

        // Verify Screen Recording TCC. The preflight gate keeps the denied
        // path fast — we never enter the SCK call below when access is denied.
        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingError.screenRecordingDenied
        }

        // SCK delivers its reply on the main run loop; an off-main call leaks
        // the continuation and hangs forever. Route through the main-actor
        // boundary (see ScreenCaptureKitBoundary.swift).
        let content = try await SCKBoundary.fetchShareableContent()
        guard let display = content.displays.first else {
            throw RecordingError.noDisplays
        }

        let width = display.width
        let height = display.height

        // Output file (same nb-screen-* pattern as captures, uses configured directory)
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let resolved = ConfigManager.shared.resolvedScreenOutputDir()
        let outputPath = "\(resolved.path)/nb-screen-\(timestamp).mp4"
        let outputURL = URL(fileURLWithPath: outputPath)

        // AVAssetWriter + H.264 video input
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw RecordingError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        recLog.info("Writer started. status=\(writer.status.rawValue) path=\(outputPath, privacy: .public) dims=\(width)x\(height)")
        // Note: startSession(atSourceTime:) is called by RecordingDelegate on first frame

        // SCStream configuration
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30 fps
        config.queueDepth = 5
        config.showsCursor = true

        let delegate = RecordingDelegate(writerInput: input, writer: writer)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(delegate, type: .screen,
                                    sampleHandlerQueue: .global(qos: .userInitiated))

        try await stream.startCapture()
        recLog.info("SCStream capture started. display=\(width)x\(height)")

        // Safety cap: auto-stop after safetyCap seconds
        let safetyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(safetyCap))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if await self.isRecording {
                do {
                    _ = try await self.stop()
                    recLog.info("Recording auto-stopped after \(Int(safetyCap))s safety cap")
                } catch {
                    recLog.error("Safety-cap auto-stop failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        recording = ActiveRecording(
            stream: stream, writer: writer, input: input,
            delegate: delegate, outputPath: outputPath,
            startTime: Date(), safetyTask: safetyTask
        )

        return (path: outputPath, width: width, height: height, isFallback: resolved.isFallback)
    }

    /// Stop the active recording. Returns (filePath, durationSeconds, bytes).
    func stop() async throws -> (path: String, duration: Double, bytes: Int64) {
        guard let rec = recording else {
            throw RecordingError.noActiveRecording
        }
        recording = nil
        rec.safetyTask?.cancel()

        // Stop capture
        try await rec.stream.stopCapture()

        // Diagnostic logging
        let frames = rec.delegate.framesWritten
        let failures = rec.delegate.appendFailures
        let skipped = rec.delegate.skippedFrames
        let status = rec.writer.status
        let writerErr = rec.writer.error?.localizedDescription ?? "nil"
        recLog.info("stop() — frames=\(frames) failures=\(failures) skipped=\(skipped) status=\(status.rawValue) error=\(writerErr, privacy: .public)")

        // Zero-frame guard: if no frames were captured, clean up and throw
        if frames == 0 {
            rec.input.markAsFinished()
            await rec.writer.finishWriting()
            try? FileManager.default.removeItem(atPath: rec.outputPath)
            throw RecordingError.noFramesCaptured
        }

        // Verify writer is still in writing state before finalization
        guard status == .writing else {
            let detail = rec.writer.error?.localizedDescription ?? "status=\(status.rawValue)"
            try? FileManager.default.removeItem(atPath: rec.outputPath)
            throw RecordingError.finalizationFailed("Writer not in writing state: \(detail)")
        }

        rec.input.markAsFinished()
        await rec.writer.finishWriting()

        // Verify finalization completed successfully (moov atom written)
        guard rec.writer.status == .completed else {
            let detail = rec.writer.error?.localizedDescription ?? "status=\(rec.writer.status.rawValue)"
            recLog.error("finishWriting() failed. status=\(rec.writer.status.rawValue) error=\(detail, privacy: .public)")
            try? FileManager.default.removeItem(atPath: rec.outputPath)
            throw RecordingError.finalizationFailed(detail)
        }

        let duration = Date().timeIntervalSince(rec.startTime)
        let attrs = try FileManager.default.attributesOfItem(atPath: rec.outputPath)
        let bytes = (attrs[.size] as? Int64) ?? 0
        recLog.info("Recording OK. duration=\(String(format: "%.2f", duration), privacy: .public)s bytes=\(bytes) frames=\(frames) skipped=\(skipped)")

        return (path: rec.outputPath, duration: duration, bytes: bytes)
    }
}
