// LogManager.swift — Structured JSON Log Writer with Rotation
// TheBridge · Security
// PKT-341: Crash resilience — persistent log to ~/Library/Logs/The Bridge/

import Foundation

/// Global file descriptor for signal handler flush.
/// Signal handlers can only call async-signal-safe functions.
/// fsync() is async-signal-safe — this is the crash breadcrumb mechanism.
nonisolated(unsafe) var _logManagerFD: Int32 = -1

/// Manages structured JSON logging to disk with file rotation.
/// Writes are serialized via actor isolation. 10MB rotation threshold.
public actor LogManager {
    public static let shared = LogManager()

    private let logDirectory: URL
    private let logFileURL: URL
    private let maxFileSize: UInt64 = 10 * 1024 * 1024 // 10MB
    private let encoder: JSONEncoder
    private var fileHandle: FileHandle?

    private init() {
        // PKT-1 v3.5: route through BridgePaths so this lands at
        // ~/Library/Logs/The Bridge/the-bridge.log alongside everything else.
        self.logDirectory = BridgePaths.logs
        self.logFileURL = logDirectory.appendingPathComponent("the-bridge.log")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    // MARK: - Bootstrap

    /// Create log directory and open file handle. Call once on app launch.
    public func bootstrap() {
        do {
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logFileURL)
            handle.seekToEndOfFile()
            self.fileHandle = handle
            _logManagerFD = handle.fileDescriptor
            print("[LogManager] Logging to \(logFileURL.path)")
        } catch {
            print("[LogManager] Bootstrap failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Write

    /// Write a structured JSON log entry to disk.
    public func write(_ entry: AuditEntry) {
        do {
            let data = try encoder.encode(entry)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            guard let lineData = line.data(using: .utf8) else { return }

            rotateIfNeeded()
            fileHandle?.write(lineData)
        } catch {
            print("[LogManager] Write error: \(error.localizedDescription)")
        }
    }

    // MARK: - Flush / Close

    /// Flush buffered data to disk. Call on app termination.
    public func flush() {
        fileHandle?.synchronizeFile()
        print("[LogManager] Flushed log to disk")
    }

    /// Close the file handle permanently.
    public func close() {
        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()
        fileHandle = nil
        _logManagerFD = -1
        print("[LogManager] Log file closed")
    }

    // MARK: - Rotation

    /// Rotate log file if it exceeds maxFileSize.
    /// Keeps one rotated backup (.log.1).
    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize >= maxFileSize else { return }

        // Close current handle
        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()

        // Rotate: current → .1 (replace if exists)
        let rotatedURL = logDirectory.appendingPathComponent("the-bridge.log.1")
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedURL)

        // Create fresh log file
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logFileURL)
        self.fileHandle = handle
        _logManagerFD = handle?.fileDescriptor ?? -1

        print("[LogManager] Log rotated (exceeded \(maxFileSize / 1024 / 1024)MB)")
    }
}
