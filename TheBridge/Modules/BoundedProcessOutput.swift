// BoundedProcessOutput.swift — concurrent, bounded process-pipe draining
// TheBridge · Modules
//
// A child can block as soon as either stdout or stderr fills its pipe buffer.
// Every caller using this helper starts both drains before waiting for exit, and
// retains a bounded head/tail representation instead of the entire stream.

import Foundation

/// A bounded, evidence-bearing snapshot of one process output stream.
public struct BoundedProcessOutputSnapshot: Sendable {
    /// The UTF-8 output retained for the caller. When truncated, this contains
    /// both the beginning and end of the stream separated by a marker.
    public let text: String
    /// Total bytes drained from the child, including bytes not retained.
    public let totalBytes: Int
    /// Source bytes retained in `text` (not including the rendered marker).
    public let capturedBytes: Int
    /// Exact number of newline-delimited lines observed in the full stream.
    public let lineCount: Int
    /// Whether bytes were omitted from the returned text.
    public let truncated: Bool
}

/// Thread-safe bounded storage for a process output stream. It preserves the
/// whole stream up to `limit`; after that point it retains evenly-budgeted head
/// and rolling-tail windows so shell head/tail selectors remain useful.
public final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let headLimit: Int
    private let tailLimit: Int
    private var head = Data()
    private var tail = Data()
    private var totalByteCount = 0
    private var newlineCount = 0
    private var endsWithNewline = false
    private var wasTruncated = false

    public init(limit: Int) {
        self.limit = max(1, limit)
        self.headLimit = max(1, self.limit / 2)
        self.tailLimit = max(0, self.limit - self.headLimit)
    }

    public func append(_ next: Data) {
        guard !next.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        totalByteCount += next.count
        newlineCount += next.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        endsWithNewline = next.last == 0x0A

        if !wasTruncated, head.count + next.count <= limit {
            head.append(next)
            return
        }

        if !wasTruncated {
            // Crossed the retention limit. Keep a head window and seed a tail
            // window from the complete stream seen through this chunk. A pipe
            // reader is allowed to return a chunk larger than the retention
            // budget, so do not assume the prior buffer alone fills the head.
            let prior = head
            head = Data(prior.prefix(headLimit))
            let remainingHeadBytes = max(0, headLimit - head.count)
            if remainingHeadBytes > 0 {
                head.append(next.prefix(remainingHeadBytes))
            }
            if tailLimit > 0 {
                if next.count >= tailLimit {
                    tail = Data(next.suffix(tailLimit))
                } else {
                    tail = Data(prior.suffix(tailLimit - next.count))
                    tail.append(next)
                }
            }
            wasTruncated = true
            return
        }

        guard tailLimit > 0 else { return }
        tail.append(next)
        if tail.count > tailLimit {
            tail.removeFirst(tail.count - tailLimit)
        }
    }

    public func snapshot() -> BoundedProcessOutputSnapshot {
        lock.lock()
        let capturedHead = head
        let capturedTail = tail
        let total = totalByteCount
        let captured = capturedHead.count + capturedTail.count
        let truncated = wasTruncated
        let lines: Int
        if total == 0 {
            lines = 0
        } else {
            lines = newlineCount + (endsWithNewline ? 0 : 1)
        }
        lock.unlock()

        if !truncated {
            return BoundedProcessOutputSnapshot(
                text: String(decoding: capturedHead, as: UTF8.self),
                totalBytes: total,
                capturedBytes: captured,
                lineCount: lines,
                truncated: false
            )
        }

        let text = String(decoding: capturedHead, as: UTF8.self)
            + "\n… [output truncated; retained beginning and end] …\n"
            + String(decoding: capturedTail, as: UTF8.self)
        return BoundedProcessOutputSnapshot(
            text: text,
            totalBytes: total,
            capturedBytes: captured,
            lineCount: lines,
            truncated: true
        )
    }
}

/// Owns concurrent stdout/stderr readers for one child process.
public final class ProcessOutputDrains: @unchecked Sendable {
    public let stdout: BoundedProcessOutput
    public let stderr: BoundedProcessOutput
    private let readers = DispatchGroup()

    private init(limitPerStream: Int) {
        stdout = BoundedProcessOutput(limit: limitPerStream)
        stderr = BoundedProcessOutput(limit: limitPerStream)
    }

    /// Starts both blocking pipe readers before the caller waits for child exit.
    public static func start(
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        limitPerStream: Int
    ) -> ProcessOutputDrains {
        let drains = ProcessOutputDrains(limitPerStream: limitPerStream)
        drains.startReader(handle: stdoutHandle, output: drains.stdout)
        drains.startReader(handle: stderrHandle, output: drains.stderr)
        return drains
    }

    public func wait() {
        readers.wait()
    }

    private func startReader(handle: FileHandle, output: BoundedProcessOutput) {
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.readers.leave() }
            while true {
                let data = handle.availableData
                if data.isEmpty { return }
                output.append(data)
            }
        }
    }
}
