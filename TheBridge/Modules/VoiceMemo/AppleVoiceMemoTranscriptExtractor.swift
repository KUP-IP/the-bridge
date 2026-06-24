// AppleVoiceMemoTranscriptExtractor.swift — embedded tsrp transcript from .m4a / .qta
// TheBridge · Modules · VoiceMemo
//
// Apple Voice Memos stores UTF-8 JSON in the `tsrp` MP4 atom (moov/trak/udta/tsrp).
// Byte-scan fallback locates `{"attributedString":` when atom walk fails.

import Foundation

public enum AppleVoiceMemoTranscriptExtractor {

    private static let containerTypes: Set<String> = ["moov", "trak", "udta", "meta", "ilst", "mdia", "minf", "stbl"]
    private static let byteScanNeedle = Data("{\"attributedString\":".utf8)

    /// Extract plain transcript text from an Apple Voice Memo container, if present.
    public static func extract(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        if let json = findTsrpJSON(in: data) {
            return plainText(from: json)
        }
        return nil
    }

    /// Whether embedded Apple transcript JSON appears present (cheap presence check).
    public static func hasEmbeddedTranscript(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return findTsrpJSON(in: data) != nil
    }

    /// Audio duration in seconds from `mvhd`, when parseable.
    public static func audioDurationSeconds(at url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return parseMvhdDuration(in: data)
    }

    // MARK: - MP4 atom walk

    private static func findTsrpJSON(in data: Data) -> [String: Any]? {
        var found: [String: Any]?
        walkAtoms(in: data, range: 0..<data.count) { type, payload in
            guard found == nil, type == "tsrp" else { return }
            if let json = decodeTsrpPayload(data[payload]) {
                found = json
            }
        }
        if let found { return found }
        return byteScanJSON(in: data)
    }

    private static func walkAtoms(
        in data: Data,
        range: Range<Int>,
        handler: (_ type: String, _ payload: Range<Int>) -> Void
    ) {
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            guard let header = readAtomHeader(in: data, at: offset, limit: range.upperBound) else { break }
            let atomEnd = offset + header.size
            guard atomEnd <= range.upperBound else { break }
            let payload = (offset + header.headerSize)..<atomEnd

            if header.type == "tsrp" {
                handler(header.type, payload)
            }

            if containerTypes.contains(header.type) {
                walkAtoms(in: data, range: payload, handler: handler)
            }

            // .qta may store tsrp under moov/meta/ilst as a named item payload.
            if header.type == "----" || header.type.hasPrefix("com.apple") {
                handler(header.type, payload)
            }

            offset = atomEnd
        }
    }

    private struct AtomHeader {
        var size: Int
        var type: String
        var headerSize: Int
    }

    private static func readAtomHeader(in data: Data, at offset: Int, limit: Int) -> AtomHeader? {
        guard offset + 8 <= limit else { return nil }
        var size = Int(readUInt32(data, offset))
        let typeData = data[(offset + 4)..<(offset + 8)]
        let type = String(decoding: typeData, as: UTF8.self)
        var headerSize = 8
        if size == 1 {
            guard offset + 16 <= limit else { return nil }
            size = Int(readUInt64(data, offset + 8))
            headerSize = 16
        }
        guard size >= headerSize, size > 0 else { return nil }
        return AtomHeader(size: size, type: type, headerSize: headerSize)
    }

    private static func decodeTsrpPayload(_ payload: Data) -> [String: Any]? {
        guard let start = payload.firstIndex(of: 0x7B) else { return nil } // '{'
        let jsonSlice = payload[start...]
        guard let obj = try? JSONSerialization.jsonObject(with: jsonSlice) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func byteScanJSON(in data: Data) -> [String: Any]? {
        guard let range = data.range(of: byteScanNeedle) else { return nil }
        let start = range.lowerBound
        // Walk back to opening brace if needle doesn't start with `{`.
        let brace = (start > data.startIndex && data[data.index(before: start)] == 0x7B)
            ? data.index(before: start)
            : start
        let slice = data[brace...]
        guard let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] else {
            return nil
        }
        return obj
    }

    // MARK: - JSON → plain text

    public static func plainText(from json: [String: Any]) -> String? {
        guard let attr = json["attributedString"] else { return nil }
        if let arr = attr as? [Any] {
            let text = arr.compactMap { $0 as? String }.joined()
            return trimmedNonEmpty(text)
        }
        if let dict = attr as? [String: Any], let runs = dict["runs"] as? [Any] {
            let text = runs.compactMap { $0 as? String }.joined()
            return trimmedNonEmpty(text)
        }
        return nil
    }

    private static func trimmedNonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - mvhd duration

    private static func parseMvhdDuration(in data: Data) -> Double? {
        var duration: Double?
        walkAtoms(in: data, range: 0..<data.count) { type, payload in
            guard duration == nil, type == "mvhd", payload.count >= 20 else { return }
            let slice = Data(data[payload])
            let version = slice[0]
            if version == 0 {
                guard slice.count >= 20 else { return }
                let timescale = readUInt32(slice, 12)
                let dur = readUInt32(slice, 16)
                guard timescale > 0 else { return }
                duration = Double(dur) / Double(timescale)
            } else if version == 1 {
                guard slice.count >= 32 else { return }
                let timescale = readUInt32(slice, 20)
                let dur = readUInt64(slice, 24)
                guard timescale > 0 else { return }
                duration = Double(dur) / Double(timescale)
            }
        }
        return duration
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return (UInt64(data[offset]) << 56)
            | (UInt64(data[offset + 1]) << 48)
            | (UInt64(data[offset + 2]) << 40)
            | (UInt64(data[offset + 3]) << 32)
            | (UInt64(data[offset + 4]) << 24)
            | (UInt64(data[offset + 5]) << 16)
            | (UInt64(data[offset + 6]) << 8)
            | UInt64(data[offset + 7])
    }
}
