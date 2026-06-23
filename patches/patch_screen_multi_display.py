#!/usr/bin/env python3
"""
Patch: Multi-Display Capture for ScreenModule.swift
Adds displayIndex parameter and all_displays target to screen_capture + screen_ocr.
"""
import re
import sys

FILE = "os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'TheBridge', 'Modules', 'ScreenModule.swift')"

with open(FILE, "r") as f:
    src = f.read()

original = src

# ── PATCH 1: Update captureImage() signature ──
# Add displayIndex parameter
old_sig = """    private static func captureImage(
        target: String,
        windowId: Int?,
        region: (x: Int, y: Int, w: Int, h: Int)?
    ) async throws -> CGImage {"""

new_sig = """    private static func captureImage(
        target: String,
        windowId: Int?,
        region: (x: Int, y: Int, w: Int, h: Int)?,
        displayIndex: Int? = nil
    ) async throws -> CGImage {"""

assert old_sig in src, "PATCH 1 FAILED: captureImage signature not found"
src = src.replace(old_sig, new_sig, 1)

# ── PATCH 2: Fix "region" case to use displayIndex ──
old_region = """        case "region":
            guard let r = region else {
                throw ScreenModuleError.missingParameter("region {x,y,w,h} required for region target")
            }
            guard let display = content.displays.first else {
                throw ScreenModuleError.noDisplays
            }"""

new_region = """        case "region":
            guard let r = region else {
                throw ScreenModuleError.missingParameter("region {x,y,w,h} required for region target")
            }
            guard !content.displays.isEmpty else {
                throw ScreenModuleError.noDisplays
            }
            let regionIdx = displayIndex ?? 0
            guard regionIdx >= 0, regionIdx < content.displays.count else {
                let available = content.displays.enumerated().map { "\\($0.offset): \\($0.element.width)x\\($0.element.height)" }.joined(separator: ", ")
                throw ScreenModuleError.missingParameter("displayIndex \\(regionIdx) out of range. Available: [\\(available)]")
            }
            let display = content.displays[regionIdx]"""

assert old_region in src, "PATCH 2 FAILED: region case not found"
src = src.replace(old_region, new_region, 1)

# ── PATCH 3: Fix "display" case to use displayIndex + add "all_displays" ──
old_display = """        default: // "display"
            guard let display = content.displays.first else {
                throw ScreenModuleError.noDisplays
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }"""

new_display = """        case "all_displays":
            guard content.displays.count > 1 else {
                throw ScreenModuleError.missingParameter("all_displays requires 2+ displays; found \\(content.displays.count)")
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
                throw ScreenModuleError.captureFailed("Failed to create composite CGContext (\\(totalWidth)x\\(maxHeight))")
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
                let available = content.displays.enumerated().map { "\\($0.offset): \\($0.element.width)x\\($0.element.height)" }.joined(separator: ", ")
                throw ScreenModuleError.missingParameter("displayIndex \\(dispIdx) out of range. Available: [\\(available)]")
            }
            let display = content.displays[dispIdx]
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }"""

assert old_display in src, "PATCH 3 FAILED: display default case not found"
src = src.replace(old_display, new_display, 1)

# ── PATCH 4: Add displayIndex to screen_capture tool schema ──
old_capture_schema_format = """                    "format": .object([
                        "type": .string("string"),
                        "description": .string("Image format: 'png' or 'jpg' (default: 'png'). JPEG uses 0.8 quality."),
                        "enum": .array([.string("png"), .string("jpg")])
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in"""

new_capture_schema_format = """                    "format": .object([
                        "type": .string("string"),
                        "description": .string("Image format: 'png' or 'jpg' (default: 'png'). JPEG uses 0.8 quality."),
                        "enum": .array([.string("png"), .string("jpg")])
                    ]),
                    "displayIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Display index to capture (default: 0 = main display). Use to target a specific monitor. Ignored when target is 'window' or 'all_displays'.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in"""

# This pattern appears twice (screen_capture + screen_ocr). We need to patch the FIRST occurrence.
assert old_capture_schema_format in src, "PATCH 4 FAILED: screen_capture schema format block not found"
src = src.replace(old_capture_schema_format, new_capture_schema_format, 1)

# ── PATCH 5: Update screen_capture target enum to include all_displays ──
old_capture_target_enum = """                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Capture target: 'display', 'window', or 'region' (default: 'display')"),
                        "enum": .array([.string("display"), .string("window"), .string("region")])
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Window ID to capture (required when target is 'window')")
                    ]),"""

new_capture_target_enum = """                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Capture target: 'display', 'window', 'region', or 'all_displays' (default: 'display')"),
                        "enum": .array([.string("display"), .string("window"), .string("region"), .string("all_displays")])
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Window ID to capture (required when target is 'window')")
                    ]),"""

# This also appears twice. Patch first (screen_capture).
assert old_capture_target_enum in src, "PATCH 5 FAILED: screen_capture target enum not found"
src = src.replace(old_capture_target_enum, new_capture_target_enum, 1)

# ── PATCH 6: Add displayIndex parsing to screen_capture handler ──
old_capture_handler_format = """                let format: String = {
                    if case .string(let f) = args["format"] { return f }
                    return "png"
                }()

                // Cleanup old capture files (best-effort, never blocks)
                cleanupCaptureFiles()

                // Capture
                let cgImage: CGImage
                do {
                    cgImage = try await captureImage(target: target, windowId: windowId, region: region)"""

new_capture_handler_format = """                let format: String = {
                    if case .string(let f) = args["format"] { return f }
                    return "png"
                }()
                let displayIndex: Int? = {
                    if case .int(let d) = args["displayIndex"] { return d }
                    return nil
                }()

                // Cleanup old capture files (best-effort, never blocks)
                cleanupCaptureFiles()

                // Capture
                let cgImage: CGImage
                do {
                    cgImage = try await captureImage(target: target, windowId: windowId, region: region, displayIndex: displayIndex)"""

assert old_capture_handler_format in src, "PATCH 6 FAILED: screen_capture handler format block not found"
src = src.replace(old_capture_handler_format, new_capture_handler_format, 1)

# ── PATCH 7: Add displayInfo to screen_capture response ──
old_capture_response = """                var response: [String: Value] = [
                    "filePath": .string(filePath),
                    "width": .int(cgImage.width),
                    "height": .int(cgImage.height),
                    "bytes": .int(fileSize),
                    "format": .string(format)
                ]
                if resolved.isFallback {
                    response["warning"] = .string("Configured output directory is invalid or not writable — fell back to /tmp")
                }
                return .object(response)"""

new_capture_response = """                // Fetch display info for response metadata
                let displayInfoArray: [Value] = {
                    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
                    return content.displays.enumerated().map { idx, d in
                        .object([
                            "index": .int(idx),
                            "width": .int(d.width),
                            "height": .int(d.height),
                            "isMain": .bool(idx == 0)
                        ])
                    }
                }()

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
                return .object(response)"""

assert old_capture_response in src, "PATCH 7 FAILED: screen_capture response block not found"
src = src.replace(old_capture_response, new_capture_response, 1)

# ── PATCH 8: Add displayIndex to screen_ocr tool schema (target enum + new param) ──
# The second occurrence of the target enum
remaining_after_first_enum = src.split(new_capture_target_enum.split("all_displays")[0], 1)
# Instead, let's patch the OCR schema similarly. Since we already patched the first occurrence,
# the second occurrence still has the old text.

# Patch OCR target enum (second occurrence - still has old text)
assert old_capture_target_enum in src, "PATCH 8a FAILED: screen_ocr target enum not found"
src = src.replace(old_capture_target_enum, new_capture_target_enum, 1)

# ── PATCH 9: Add displayIndex param to screen_ocr schema ──
# The OCR schema has "language" instead of "format" as the last param before required
old_ocr_schema_language = """                    "language": .object([
                        "type": .string("string"),
                        "description": .string("OCR recognition language (default: 'en'). Supports ISO 639-1 codes.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in"""

new_ocr_schema_language = """                    "language": .object([
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
            handler: { arguments in"""

assert old_ocr_schema_language in src, "PATCH 9 FAILED: screen_ocr language schema not found"
src = src.replace(old_ocr_schema_language, new_ocr_schema_language, 1)

# ── PATCH 10: Add displayIndex parsing + pass-through to screen_ocr handler ──
old_ocr_handler = """                let language: String = {
                    if case .string(let l) = args["language"] { return l }
                    return "en"
                }()

                // Capture screen
                let cgImage: CGImage
                do {
                    cgImage = try await captureImage(target: target, windowId: windowId, region: region)"""

new_ocr_handler = """                let language: String = {
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
                    cgImage = try await captureImage(target: target, windowId: windowId, region: region, displayIndex: displayIndex)"""

assert old_ocr_handler in src, "PATCH 10 FAILED: screen_ocr handler block not found"
src = src.replace(old_ocr_handler, new_ocr_handler, 1)

# ── Verify all patches applied ──
assert src != original, "ERROR: No changes were made"

with open(FILE, "w") as f:
    f.write(src)

# Count changes
import difflib
diff = list(difflib.unified_diff(original.splitlines(), src.splitlines(), lineterm=""))
added = sum(1 for l in diff if l.startswith("+") and not l.startswith("+++"))
removed = sum(1 for l in diff if l.startswith("-") and not l.startswith("---"))

print(f"✅ All 10 patches applied successfully")
print(f"   +{added} lines added, -{removed} lines removed")
print(f"   File: {FILE}")
