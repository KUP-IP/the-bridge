// ScreenModule.swift – V3-SCREEN-001 Screen Capture & OCR Tools
// TheBridge · Modules
//
// Two read-only tools: screen_capture (Open), screen_ocr (Open).
// Uses ScreenCaptureKit for capture, Vision framework for OCR.
// Both classified as Open tier (read-only, zero side effects).
// PKT-354: Pull-forward of Phase 4 ScreenModule — read tools only.
//
// Frameworks:
//   - ScreenCaptureKit: SCScreenshotManager.captureImage for screenshots
//   - Vision: VNRecognizeTextRequest for OCR
//   - ImageIO: CGImageDestination for PNG/JPEG encoding (Sendable-safe)
//   - CoreGraphics: CGPreflightScreenCaptureAccess for TCC detection
//
// Capture files: <configuredDir>/nb-screen-<timestamp>.<ext> (default ~/Desktop, fallback /tmp)
// Cleanup: On each screen_capture call, delete files >1hr old, cap at 20.

import MCP
import AppKit
import ScreenCaptureKit
import Vision
import ImageIO
import UniformTypeIdentifiers

// MARK: - ScreenModule

/// Provides screen capture and OCR tools using ScreenCaptureKit + Vision.
public enum ScreenModule {

    public static let moduleName = "screen"

    // MARK: - Cleanup

    /// Best-effort cleanup of old capture files.
    /// Deletes nb-screen-* files older than 1 hour, then caps at 20 remaining.
    /// Failures are logged but never block the capture operation.
    private static func cleanupCaptureFiles() {
        let resolved = ConfigManager.shared.resolvedScreenOutputDir()
        let tmpDir = resolved.path
        let prefix = "nb-screen-"
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let fm = FileManager.default

        do {
            let allFiles = try fm.contentsOfDirectory(atPath: tmpDir)
            let captureFiles = allFiles.filter { $0.hasPrefix(prefix) }

            // Phase 1: Delete files older than 1 hour
            for name in captureFiles {
                let path = "\(tmpDir)/\(name)"
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let modified = attrs[.modificationDate] as? Date,
                   modified < oneHourAgo {
                    try? fm.removeItem(atPath: path)
                }
            }

            // Phase 2: Cap at 20 files (delete oldest first)
            let remaining = try fm.contentsOfDirectory(atPath: tmpDir)
                .filter { $0.hasPrefix(prefix) }
                .compactMap { name -> (path: String, date: Date)? in
                    let path = "\(tmpDir)/\(name)"
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let modified = attrs[.modificationDate] as? Date else { return nil }
                    return (path: path, date: modified)
                }
                .sorted { $0.date < $1.date }

            if remaining.count > 20 {
                for file in remaining.prefix(remaining.count - 20) {
                    try? fm.removeItem(atPath: file.path)
                }
            }
        } catch {
            // Best-effort — never block capture
        }
    }

    // MARK: - Frontmost Guard

    /// The bundle identifier of the frontmost (active) application, if any.
    /// Read on the main actor — `NSWorkspace.frontmostApplication` is
    /// main-actor-isolated and stale reads off-main are unreliable.
    @MainActor
    private static func frontmostBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// FB-AUTOMATION: optional guard for `screen_capture`. When the caller
    /// passes `requireFrontmostBundleId`, the capture only proceeds if that
    /// bundle id is currently frontmost. Lets an agent assert the expected app
    /// (e.g. The Bridge after bridge_focus_settings) is actually in front before
    /// spending a capture — and surface a clear error if focus was stolen.
    /// Returns the structured-error `Value` to short-circuit with, or nil to
    /// proceed.
    @MainActor
    private static func frontmostGuardFailure(required: String?) -> Value? {
        guard let required, !required.isEmpty else { return nil }
        let actual = frontmostBundleId()
        if actual == required { return nil }
        return .object([
            "error": .string("frontmost_mismatch"),
            "message": .string("Required frontmost app '\(required)' is not active (frontmost: '\(actual ?? "unknown")'). Capture aborted. Bring the app forward (e.g. bridge_focus_settings) and retry."),
            "requiredBundleId": .string(required),
            "frontmostBundleId": actual.map { Value.string($0) } ?? .null
        ])
    }

    // MARK: - Capture Helpers

    /// Verify Screen Recording TCC grant and fetch shareable content.
    /// Uses CGPreflightScreenCaptureAccess() only — never CGRequestScreenCaptureAccess()
    /// (which opens a modal dialog, inappropriate at tool-call time).
    private static func getShareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenModuleError.screenRecordingDenied
        }
        // SCK delivers its reply on the main run loop; calling it off the main
        // actor leaks the continuation and hangs forever. Route through the
        // main-actor boundary (see ScreenCaptureKitBoundary.swift). The
        // preflight gate above keeps the denied path fast — we never reach the
        // SCK call when access is not granted.
        return try await SCKBoundary.fetchShareableContent()
    }

    /// Capture a CGImage based on target parameters.
    ///
    /// `@MainActor`: every ScreenCaptureKit async API used here
    /// (`SCShareableContent.excludingDesktopWindows` via `getShareableContent`
    /// and `SCScreenshotManager.captureImage`) delivers its reply on the main
    /// run loop. Calling them off the main actor leaks the checked continuation
    /// and hangs forever (it was masked only because GUI dispatch ran on main;
    /// it surfaces as intermittent suite hangs from the nonisolated test
    /// harness). Pinning the whole helper to the main actor makes every SCK
    /// reply land on a serviced context. The fast denied-path short-circuit is
    /// preserved: `getShareableContent` preflights TCC and throws before any
    /// SCK call.
    @MainActor
    private static func captureImage(
        target: String,
        windowId: Int?,
        region: (x: Int, y: Int, w: Int, h: Int)?,
        displayIndex: Int? = nil
    ) async throws -> CGImage {
        let content = try await getShareableContent()

        switch target {
        case "window":
            guard let wid = windowId else {
                throw ScreenModuleError.missingParameter("windowId required for window target")
            }
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(wid) }) else {
                throw ScreenModuleError.windowNotFound(wid)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width) * 2
            config.height = Int(window.frame.height) * 2
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        case "region":
            guard let r = region else {
                throw ScreenModuleError.missingParameter("region {x,y,w,h} required for region target")
            }
            guard !content.displays.isEmpty else {
                throw ScreenModuleError.noDisplays
            }
            let regionIdx = displayIndex ?? 0
            guard regionIdx >= 0, regionIdx < content.displays.count else {
                let available = content.displays.enumerated().map { "\($0.offset): \($0.element.width)x\($0.element.height)" }.joined(separator: ", ")
                throw ScreenModuleError.missingParameter("displayIndex \(regionIdx) out of range. Available: [\(available)]")
            }
            let display = content.displays[regionIdx]
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            config.width = r.w
            config.height = r.h
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        case "all_displays":
            guard content.displays.count > 1 else {
                throw ScreenModuleError.missingParameter("all_displays requires 2+ displays; found \(content.displays.count)")
            }
            var images: [CGImage] = []
            for disp in content.displays {
                let f = SCContentFilter(display: disp, excludingWindows: [])
                let c = SCStreamConfiguration()
                c.width = disp.width * 2
                c.height = disp.height * 2
                c.scalesToFit = false
                images.append(try await SCScreenshotManager.captureImage(contentFilter: f, configuration: c))
            }
            let totalWidth = images.reduce(0) { $0 + $1.width }
            let maxHeight = images.map { $0.height }.max() ?? 0
            guard let ctx = CGContext(
                data: nil, width: totalWidth, height: maxHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else {
                throw ScreenModuleError.captureFailed("Failed to create composite CGContext (\(totalWidth)x\(maxHeight))")
            }
            var xOffset = 0
            for img in images {
                ctx.draw(img, in: CGRect(x: xOffset, y: maxHeight - img.height, width: img.width, height: img.height))
                xOffset += img.width
            }
            guard let composite = ctx.makeImage() else {
                throw ScreenModuleError.captureFailed("Failed to finalize composite image")
            }
            return composite

        default: // "display"
            guard !content.displays.isEmpty else {
                throw ScreenModuleError.noDisplays
            }
            let dispIdx = displayIndex ?? 0
            guard dispIdx >= 0, dispIdx < content.displays.count else {
                let available = content.displays.enumerated().map { "\($0.offset): \($0.element.width)x\($0.element.height)" }.joined(separator: ", ")
                throw ScreenModuleError.missingParameter("displayIndex \(dispIdx) out of range. Available: [\(available)]")
            }
            let display = content.displays[dispIdx]
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// Encode a CGImage to disk as PNG or JPEG using ImageIO (Sendable-safe, no AppKit).
    private static func writeImage(_ cgImage: CGImage, format: String, to path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        let utType: CFString = format == "jpg"
            ? UTType.jpeg.identifier as CFString
            : UTType.png.identifier as CFString

        guard let destination = CGImageDestinationCreateWithURL(url, utType, 1, nil) else {
            throw ScreenModuleError.encodingFailed(format)
        }

        let options: [CFString: Any] = format == "jpg"
            ? [kCGImageDestinationLossyCompressionQuality: 0.8]
            : [:]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ScreenModuleError.encodingFailed(format)
        }
    }

    // MARK: - Registration

    /// Register all ScreenModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. screen_capture – Open (read-only)
        await router.register(ToolRegistration(
            name: "screen_capture",
            module: moduleName,
            tier: .open,
            description: "Screenshot a display, window, region, or all displays as PNG/JPG. Static image only; for motion use screen_record_start.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Capture target: 'display', 'window', 'region', or 'all_displays' (default: 'display')"),
                        "enum": .array([.string("display"), .string("window"), .string("region"), .string("all_displays")])
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Window ID to capture (required when target is 'window')")
                    ]),
                    "region": .object([
                        "type": .string("object"),
                        "description": .string("Region to capture: {x, y, w, h} in screen coordinates (required when target is 'region')"),
                        "properties": .object([
                            "x": .object(["type": .string("integer")]),
                            "y": .object(["type": .string("integer")]),
                            "w": .object(["type": .string("integer")]),
                            "h": .object(["type": .string("integer")])
                        ])
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "description": .string("Image format: 'png' or 'jpg' (default: 'png'). JPEG uses 0.8 quality."),
                        "enum": .array([.string("png"), .string("jpg")])
                    ]),
                    "displayIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Display index to capture (default: 0 = main display). Use to target a specific monitor. Ignored when target is 'window' or 'all_displays'.")
                    ]),
                    "requireFrontmostBundleId": .object([
                        "type": .string("string"),
                        "description": .string("Optional guard: only capture if this app bundle id is currently frontmost (e.g. 'com.keepr.TheBridge'). Returns error='frontmost_mismatch' and skips the capture otherwise. Pair with bridge_focus_settings to assert The Bridge is in front before capturing it.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                let target: String = {
                    if case .string(let t) = args["target"] { return t }
                    return "display"
                }()
                let windowId: Int? = {
                    if case .int(let w) = args["windowId"] { return w }
                    return nil
                }()
                let region: (x: Int, y: Int, w: Int, h: Int)? = {
                    if case .object(let r) = args["region"],
                       case .int(let x) = r["x"],
                       case .int(let y) = r["y"],
                       case .int(let w) = r["w"],
                       case .int(let h) = r["h"] {
                        return (x: x, y: y, w: w, h: h)
                    }
                    return nil
                }()
                let format: String = {
                    if case .string(let f) = args["format"] { return f }
                    return "png"
                }()
                let displayIndex: Int? = {
                    if case .int(let d) = args["displayIndex"] { return d }
                    return nil
                }()
                let requireFrontmost: String? = {
                    if case .string(let b) = args["requireFrontmostBundleId"] { return b }
                    return nil
                }()

                // FB-AUTOMATION: frontmost-app guard (opt-in). Short-circuit
                // before any capture work if the required app is not in front.
                if let guardFailure = await frontmostGuardFailure(required: requireFrontmost) {
                    return guardFailure
                }

                // Cleanup old capture files (best-effort, never blocks)
                cleanupCaptureFiles()

                // Capture
                let cgImage: CGImage
                do {
                    cgImage = try await captureImage(target: target, windowId: windowId, region: region, displayIndex: displayIndex)
                } catch let error as ScreenModuleError {
                    return error.toResponse()
                } catch {
                    return ScreenModuleError.captureFailed("Screen capture failed: \(error.localizedDescription)").toResponse()
                }

                // Encode to file
                let ext = format == "jpg" ? "jpg" : "png"
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let resolved = ConfigManager.shared.resolvedScreenOutputDir()
                let filePath = "\(resolved.path)/nb-screen-\(timestamp).\(ext)"

                do {
                    try writeImage(cgImage, format: format, to: filePath)
                } catch let error as ScreenModuleError {
                    // PKT-373 P2-2: Clean up partial file on failure
                    try? FileManager.default.removeItem(atPath: filePath)
                    return error.toResponse()
                } catch {
                    // PKT-373 P2-2: Clean up partial file on failure
                    try? FileManager.default.removeItem(atPath: filePath)
                    return ScreenModuleError.captureFailed("Failed to write image to \(filePath): \(error.localizedDescription)").toResponse()
                }

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int) ?? 0

                // Fetch display info for response metadata. Route through the
                // main-actor SCK boundary — an off-main call leaks its
                // continuation and hangs. `try?` keeps metadata best-effort.
                let displayInfoArray: [Value]
                if let content = try? await SCKBoundary.fetchShareableContent() {
                    displayInfoArray = content.displays.enumerated().map { idx, d in
                        .object([
                            "index": .int(idx),
                            "width": .int(d.width),
                            "height": .int(d.height),
                            "isMain": .bool(idx == 0)
                        ])
                    }
                } else {
                    displayInfoArray = []
                }

                var response: [String: Value] = [
                    "filePath": .string(filePath),
                    "width": .int(cgImage.width),
                    "height": .int(cgImage.height),
                    "bytes": .int(fileSize),
                    "format": .string(format),
                    "displayCount": .int(displayInfoArray.count),
                    "displays": .array(displayInfoArray)
                ]
                if resolved.isFallback {
                    response["warning"] = .string("Configured output directory is invalid or not writable — fell back to /tmp")
                }
                return .object(response)
            }
        ))

        // MARK: 2. screen_ocr – Open (read-only)
        await router.register(ToolRegistration(
            name: "screen_ocr",
            module: moduleName,
            tier: .open,
            description: "Run Vision OCR on a live display/window/region and return recognized text with confidences + bounding boxes. Pair with screen_capture if you also need the PNG.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Capture target: 'display', 'window', 'region', or 'all_displays' (default: 'display')"),
                        "enum": .array([.string("display"), .string("window"), .string("region"), .string("all_displays")])
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Window ID to capture (required when target is 'window')")
                    ]),
                    "region": .object([
                        "type": .string("object"),
                        "description": .string("Region to capture: {x, y, w, h} in screen coordinates (required when target is 'region')"),
                        "properties": .object([
                            "x": .object(["type": .string("integer")]),
                            "y": .object(["type": .string("integer")]),
                            "w": .object(["type": .string("integer")]),
                            "h": .object(["type": .string("integer")])
                        ])
                    ]),
                    "language": .object([
                        "type": .string("string"),
                        "description": .string("OCR recognition language (default: 'en'). Supports ISO 639-1 codes.")
                    ]),
                    "displayIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Display index for capture (default: 0 = main display). Use to target a specific monitor. Ignored when target is 'window' or 'all_displays'.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                let target: String = {
                    if case .string(let t) = args["target"] { return t }
                    return "display"
                }()
                let windowId: Int? = {
                    if case .int(let w) = args["windowId"] { return w }
                    return nil
                }()
                let region: (x: Int, y: Int, w: Int, h: Int)? = {
                    if case .object(let r) = args["region"],
                       case .int(let x) = r["x"],
                       case .int(let y) = r["y"],
                       case .int(let w) = r["w"],
                       case .int(let h) = r["h"] {
                        return (x: x, y: y, w: w, h: h)
                    }
                    return nil
                }()
                let language: String = {
                    if case .string(let l) = args["language"] { return l }
                    return "en"
                }()
                let displayIndex: Int? = {
                    if case .int(let d) = args["displayIndex"] { return d }
                    return nil
                }()

                // Capture screen
                let cgImage: CGImage
                do {
                    cgImage = try await captureImage(target: target, windowId: windowId, region: region, displayIndex: displayIndex)
                } catch let error as ScreenModuleError {
                    return error.toResponse()
                } catch {
                    return ScreenModuleError.captureFailed("Screen capture failed: \(error.localizedDescription)").toResponse()
                }

                // Run Vision OCR
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = [language]
                    request.usesLanguageCorrection = true

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])

                    guard let observations = request.results, !observations.isEmpty else {
                        // Empty result is valid (blank screen, no visible text) — not an error
                        return .object([
                            "text": .string(""),
                            "confidence": .double(0.0),
                            "bounds": .array([])
                        ])
                    }

                    var fullText = ""
                    var totalConfidence: Float = 0
                    var bounds: [Value] = []

                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        fullText += candidate.string + "\n"
                        totalConfidence += candidate.confidence

                        let box = observation.boundingBox
                        bounds.append(.object([
                            "text": .string(candidate.string),
                            "confidence": .double(Double(candidate.confidence)),
                            "rect": .object([
                                "x": .double(box.origin.x),
                                "y": .double(box.origin.y),
                                "width": .double(box.size.width),
                                "height": .double(box.size.height)
                            ])
                        ]))
                    }

                    let avgConfidence = Double(totalConfidence) / Double(observations.count)

                    return .object([
                        "text": .string(fullText.trimmingCharacters(in: .whitespacesAndNewlines)),
                        "confidence": .double((avgConfidence * 1000).rounded() / 1000),
                        "bounds": .array(bounds)
                    ])
                } catch {
                    return .object([
                        "error": .string("ocr_failed"),
                        "message": .string("Vision text recognition failed: \(error.localizedDescription)")
                    ])
                }
            }
        ))
    }
}

// MARK: - Errors

/// Structured error types for ScreenModule — all return JSON responses, never crash.
private enum ScreenModuleError: Error {
    case screenRecordingDenied
    case noDisplays
    case windowNotFound(Int)
    case missingParameter(String)
    case encodingFailed(String)
    case captureFailed(String)

    func toResponse() -> Value {
        switch self {
        case .screenRecordingDenied:
            return .object([
                "error": .string("screen_recording_denied"),
                "message": .string("Screen Recording permission not granted. Open System Settings > Privacy & Security > Screen Recording and enable The Bridge.")
            ])
        case .noDisplays:
            return .object([
                "error": .string("no_displays"),
                "message": .string("No capturable displays found.")
            ])
        case .windowNotFound(let id):
            return .object([
                "error": .string("window_not_found"),
                "message": .string("Window ID \(id) not found in capturable windows.")
            ])
        case .missingParameter(let msg):
            return .object([
                "error": .string("invalid_parameters"),
                "message": .string(msg)
            ])
        case .encodingFailed(let format):
            return .object([
                "error": .string("encoding_failed"),
                "message": .string("Failed to encode image as \(format).")
            ])
        case .captureFailed(let msg):
            return .object([
                "error": .string("capture_failed"),
                "message": .string(msg)
            ])
        }
    }
}
