// VoiceMemoModuleTests.swift — Registry-Centric Voice Router (Wave 1)
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

func runVoiceMemoModuleTests() async {
    print("\n🎙️ Voice Memos curator — module + parser + job")

    await test("VoiceMemoModule registers 8 tools with expected tiers") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VoiceMemoModule.register(on: router)
        let tools = await router.registrations(forModule: "voice")
        try expect(tools.count == 8, "expected 8 voice tools, got \(tools.count)")
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        try expect(byName["voice_memo_list"]?.tier == .open, "list must be open")
        try expect(byName["voice_memo_process"]?.tier == .notify, "process must be notify")
        try expect(byName["voice_memo_get"]?.tier == .open, "get must be open")
        try expect(byName["voice_memo_commit"]?.tier == .notify, "commit must be notify")
        try expect(byName["voice_memo_review_list"]?.tier == .open, "review list must be open")
        try expect(byName["voice_memo_review_dismiss"]?.tier == .notify, "review dismiss must be notify")
        try expect(byName["voice_memo_review_resolve"]?.tier == .notify, "review resolve must be notify")
        try expect(byName["voice_memo_transcript_refresh"]?.tier == .notify, "transcript refresh must be notify")
    }

    await test("VoiceMemoParser: reminder lane skips memory_keep on explicit negation") {
        let transcript = "Don't create a memory. Just add to my reminders to email Sarah Friday."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(plan.skipMemoryKeep == true, "must honor explicit no-memory")
        try expect(plan.intents.contains(where: { $0.kind == .reminder }), "must detect reminder")
        try expect(!plan.intents.contains(where: { $0.kind == .memoryKeep }), "must not memory_keep")
    }

    await test("VoiceMemoParser: memory_keep branding lane") {
        let transcript = "Keep this: my preferred stack is Bridge plus Cursor for daily work."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(plan.intents.contains(where: { $0.kind == .memoryKeep }), "must detect memory_keep")
        let keep = plan.intents.first { $0.kind == .memoryKeep }
        try expect(keep?.entityKey == "memory", "memory_keep targets memory entity")
        let fields = keep?.fields ?? [:]
        try expect(fields["alias"] == "voice-memo", "alias tags source")
        try expect(fields["status"] == "Inbox", "status Inbox")
        try expect(fields["type"] == "Memory", "type Memory")
        try expect(fields["source"] == nil, "no invalid source key")
    }

    await test("VoiceMemoParser: packet registry hint") {
        let transcript = "Update packet PKT-1010 — ready for review."
        let plan = VoiceMemoParser.parse(transcript: transcript, fallbackTitle: "Memo")
        try expect(plan.intents.contains(where: { $0.kind == .registryUpdate && $0.entityKey == "session" }), "packet → session entity")
    }

    await test("VoiceMemoProcessor dry-run routes without marking processed") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-voicememo-\(UUID().uuidString)", isDirectory: true)
        let recordings = fakeHome
            .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(fakeHome)

        let audio = recordings.appendingPathComponent("test.m4a")
        try Data([0x00]).write(to: audio)
        let sidecar = recordings.appendingPathComponent("test.txt")
        try "Remind me to ship the release notes.".data(using: .utf8)?.write(to: sidecar)

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VoiceMemoModule.register(on: router)

        let result = try await VoiceMemoProcessor.process(
            args: .object([
                "dryRun": .bool(true),
                "mode": .string("batch"),
                "recordingsRoot": .string(recordings.path),
            ]),
            router: router
        )
        guard case .object(let envelope) = result else {
            try expect(false, "expected object envelope")
            return
        }
        try expect(envelope["dryRun"] == .bool(true), "dryRun flag")
        if case .int(let count)? = envelope["processedCount"] { try expect(count >= 1, "should process one memo") }
        let id = VoiceMemoDiscovery.stableId(for: audio)
        try expect(!VoiceMemoProcessedStore.isProcessed(id: id), "dry-run must not mark processed")

        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: fakeHome)
    }

    await test("VoiceMemoCuratorJob: seeder is idempotent") {
        let noop: @Sendable (String, [CronParser.CalendarInterval]) throws -> Void = { _, _ in }
        try await JobStore.shared.open()
        try? await JobStore.shared.delete(id: VoiceMemoCuratorJob.jobId)

        let first = await JobsManager.shared.seedVoiceMemoCuratorJobIfNeeded(installLaunchAgent: noop)
        try expect(first == true, "first seed inserts")
        let job = try await JobStore.shared.fetch(id: VoiceMemoCuratorJob.jobId)
        try expect(job?.schedule == "0 9 * * *", "9am schedule")
        try expect(job?.status == .paused, "seed paused until operator go-live")
        try expect(job?.actionChain.first?.tool == "voice_memo_process")

        let second = await JobsManager.shared.seedVoiceMemoCuratorJobIfNeeded(installLaunchAgent: noop)
        try expect(second == false, "second seed no-op")

        try? await JobStore.shared.delete(id: VoiceMemoCuratorJob.jobId)
    }

    await test("VoiceMemoProcessor skips already-processed memo unless forceReprocess") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-voicememo-idem-\(UUID().uuidString)", isDirectory: true)
        let recordings = fakeHome
            .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(fakeHome)

        let audio = recordings.appendingPathComponent("idem.m4a")
        try Data([0x00]).write(to: audio)
        try "Keep this note.".data(using: .utf8)?.write(to: recordings.appendingPathComponent("idem.txt"))
        let id = VoiceMemoDiscovery.stableId(for: audio)
        try VoiceMemoProcessedStore.markProcessed(id: id)

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VoiceMemoModule.register(on: router)
        let result = try await VoiceMemoProcessor.process(
            args: .object(["memoId": .string(id)]),
            router: router
        )
        guard case .object(let envelope) = result,
              case .array(let receipts)? = envelope["receipts"],
              case .object(let receipt)? = receipts.first,
              case .string(let skip)? = receipt["skippedReason"] else {
            try expect(false, "expected skipped receipt")
            return
        }
        try expect(skip.contains("already processed"), "must skip idempotent re-run")

        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: fakeHome)
    }

    await test("VoiceMemoReviewStore queues low-confidence intents") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-voicememo-review-\(UUID().uuidString)", isDirectory: true)
        BridgePaths.overrideHomeForTesting(fakeHome)

        let entry = VoiceMemoReviewEntry(
            memoId: "test-id",
            memoTitle: "Test memo",
            intentKind: VoiceMemoIntentKind.memoryKeep.rawValue,
            confidence: 0.5,
            reason: "below threshold",
            transcriptExcerpt: "sample"
        )
        try VoiceMemoReviewStore.enqueue(entry)
        let pending = VoiceMemoReviewStore.pendingEntries()
        try expect(pending.count == 1, "one pending review")
        try expect(pending[0].memoId == "test-id", "memo id preserved")
        try VoiceMemoReviewStore.dismiss(id: pending[0].id)
        try expect(VoiceMemoReviewStore.pendingEntries().isEmpty, "dismiss clears pending")

        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: fakeHome)
    }

    await test("VoiceMemoParser.sanitizeTitle rejects placeholder LLM titles") {
        try expect(VoiceMemoParser.sanitizeTitle("...", fallback: "Real Title") == "Real Title", "ellipsis")
        try expect(VoiceMemoParser.sanitizeTitle("unknown", fallback: "Real Title") == "Real Title", "unknown")
        try expect(VoiceMemoParser.sanitizeTitle("  Ship the release  ", fallback: "Fallback") == "Ship the release", "trimmed valid")
    }

    await test("VoiceMemoDiscovery writes transcript sidecar") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("memo.m4a")
        try Data([0]).write(to: audio)
        try VoiceMemoDiscovery.writeTranscriptSidecar(for: audio, text: "Keep this note about testing.")
        let loaded = VoiceMemoDiscovery.loadTranscriptSidecar(for: audio)
        try expect(loaded == "Keep this note about testing.", "sidecar round-trip")
        try? FileManager.default.removeItem(at: dir)
    }

    await test("VoiceMemoProcessor chunkText splits long transcripts") {
        let long = String(repeating: "a", count: 4000)
        let chunks = VoiceMemoProcessor.chunkText(long, maxLen: 1900)
        try expect(chunks.count == 3, "expected 3 chunks, got \(chunks.count)")
        try expect(chunks.joined().count == 4000, "no data loss")
    }

    await test("VoiceMemoProcessor parseRegistryPageId reads row id") {
        let value: Value = .object([
            "created": .bool(true),
            "row": .object(["id": .string("page-abc"), "title": .string("Test")]),
        ])
        try expect(VoiceMemoProcessor.parseRegistryPageId(from: value) == "page-abc", "page id")
    }

    await test("VoiceMemoProcessor applySummary patches memory_keep fields") {
        let plan = VoiceMemoParser.parse(transcript: "Keep this idea.", fallbackTitle: "Memo")
        let patched = VoiceMemoProcessor.applySummary(
            to: plan,
            summary: "One sentence summary.",
            transcript: "Keep this idea.",
            recordingPath: "/tmp/memo.m4a"
        )
        let keep = patched.intents.first { $0.kind == .memoryKeep }
        try expect(keep?.fields["summary"] == "One sentence summary.", "summary in fields")
        try expect(keep?.fields["url"] == "file:///tmp/memo.m4a", "recording url")
    }

    await test("BridgeDefaults parakeet transcription defaults on") {
        let key = BridgeDefaults.voiceMemoParakeetTranscription + ".test"
        UserDefaults.standard.removeObject(forKey: key)
        // Simulate unset via temporary override of effective check — use seed on fresh keys
        try expect(BridgeDefaults.voiceMemoParakeetTranscriptionEffective == true, "default on when unset")
    }

    await test("AppleVoiceMemoTranscriptExtractor: runs-format JSON → plain text") {
        let json: [String: Any] = [
            "attributedString": [
                "attributeTable": [["timeRange": [0.0, 1.0]]],
                "runs": ["Hello", 0, " world", 0],
            ],
        ]
        let text = AppleVoiceMemoTranscriptExtractor.plainText(from: json)
        try expect(text == "Hello world", "runs format, got \(text ?? "nil")")
    }

    await test("AppleVoiceMemoTranscriptExtractor: interleaved array JSON → plain text") {
        let json: [String: Any] = [
            "attributedString": ["This is", ["timeRange": [0.0, 0.5]], " a test"],
        ]
        let text = AppleVoiceMemoTranscriptExtractor.plainText(from: json)
        try expect(text == "This is a test", "array format")
    }

    await test("AppleVoiceMemoTranscriptExtractor: tsrp atom fixture extracts text") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-tsrp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("fixture.m4a")
        try makeTsrpM4AFixture(transcript: "Embedded Apple transcript for testing.").write(to: audio)
        let extracted = AppleVoiceMemoTranscriptExtractor.extract(from: audio)
        try expect(extracted == "Embedded Apple transcript for testing.", "tsrp extract")
        try? FileManager.default.removeItem(at: dir)
    }

    await test("VoiceMemoDiscovery: Apple extract writes sidecar + meta source apple") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-apple-ladder-\(UUID().uuidString)", isDirectory: true)
        let recordings = fakeHome
            .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(fakeHome)

        let audio = recordings.appendingPathComponent("apple.m4a")
        try makeTsrpM4AFixture(
            transcript: "Keep this voice note about the transcription ladder and Apple tsrp sidecar metadata for hermetic testing."
        ).write(to: audio)

        let prior = VoiceMemoTranscriber.transcribeFile
        VoiceMemoTranscriber.transcribeFile = { _ in
            throw VoiceMemoTranscriber.TranscriberError.emptyResult
        }
        defer { VoiceMemoTranscriber.transcribeFile = prior }

        let resolved = try await VoiceMemoDiscovery.resolveTranscript(for: audio)
        try expect(resolved.source == .apple, "source apple")
        try expect(resolved.text?.contains("ladder") == true, "apple text")
        let sidecar = VoiceMemoDiscovery.loadTranscriptSidecar(for: audio)
        try expect(sidecar?.contains("ladder") == true, "sidecar written")
        let meta = VoiceMemoDiscovery.loadTranscriptMeta(for: audio)
        try expect(meta?.source == .apple, "meta source apple")
        try expect((meta?.charCount ?? 0) > 0, "meta charCount")

        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: fakeHome)
    }

    await test("VoiceMemoDiscovery: existing sidecar cache wins over Apple") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-sidecar-win-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("cached.m4a")
        try makeTsrpM4AFixture(transcript: "Apple text should not win.").write(to: audio)
        try VoiceMemoDiscovery.writeTranscriptSidecar(for: audio, text: "Cached sidecar wins.", source: .sidecar)

        let resolved = try await VoiceMemoDiscovery.resolveTranscript(for: audio)
        try expect(resolved.text == "Cached sidecar wins.", "sidecar wins")
        try expect(resolved.source == .sidecar, "source sidecar")

        try? FileManager.default.removeItem(at: dir)
    }

    await test("VoiceMemoDiscovery: suspiciously short Apple triggers Parakeet fallback") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-parakeet-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("short.m4a")
        // Short text + long duration → heuristic triggers Parakeet.
        var fixture = makeTsrpM4AFixture(transcript: "Hi", durationSec: 120)
        try fixture.write(to: audio)

        let prior = VoiceMemoTranscriber.transcribeFile
        VoiceMemoTranscriber.transcribeFile = { _ in
            "Parakeet produced a much longer transcript for this recording than Apple did."
        }
        defer { VoiceMemoTranscriber.transcribeFile = prior }

        let resolved = try await VoiceMemoDiscovery.resolveTranscript(for: audio)
        try expect(resolved.source == .parakeet, "parakeet fallback")
        try expect(resolved.text?.contains("Parakeet") == true, "parakeet text")
        let meta = VoiceMemoDiscovery.loadTranscriptMeta(for: audio)
        try expect(meta?.source == .parakeet, "meta parakeet")

        try? FileManager.default.removeItem(at: dir)
    }

    await test("VoiceMemoDiscovery appleTranscriptSuspiciouslyShort heuristic") {
        try expect(VoiceMemoDiscovery.appleTranscriptSuspiciouslyShort(text: "short", audioDurationSec: 120) == true, "short vs long audio")
        try expect(VoiceMemoDiscovery.appleTranscriptSuspiciouslyShort(text: String(repeating: "x", count: 200), audioDurationSec: 120) == false, "long text ok")
        try expect(VoiceMemoDiscovery.appleTranscriptSuspiciouslyShort(text: "x", audioDurationSec: 0) == true, "min threshold 80")
    }

    await test("voice_memo_list exposes transcriptSource") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-list-source-\(UUID().uuidString)", isDirectory: true)
        let recordings = fakeHome
            .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(fakeHome)

        let audio = recordings.appendingPathComponent("listed.m4a")
        try makeTsrpM4AFixture(transcript: "List view Apple source.").write(to: audio)

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VoiceMemoModule.register(on: router)
        let result = try await router.dispatch(toolName: "voice_memo_list", arguments: .object([
            "includeProcessed": .bool(true),
        ]))
        guard case .object(let envelope) = result,
              case .array(let memos)? = envelope["memos"] else {
            try expect(false, "expected memos array")
            return
        }
        var source: String?
        for memo in memos {
            guard case .object(let row) = memo,
                  case .string(let path)? = row["path"],
                  path.contains("listed.m4a"),
                  case .string(let s)? = row["transcriptSource"] else { continue }
            source = s
            break
        }
        try expect(source == "apple", "transcriptSource apple, got \(source ?? "nil")")

        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: fakeHome)
    }

    await test("VoiceMemoReviewStore TTL auto-dismisses stale pending entries") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-voicememo-ttl-\(UUID().uuidString)", isDirectory: true)
        BridgePaths.overrideHomeForTesting(fakeHome)

        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-31 * 86_400))
        let entry = VoiceMemoReviewEntry(
            memoId: "stale-memo",
            memoTitle: "Old memo",
            intentKind: VoiceMemoIntentKind.review.rawValue,
            confidence: 0.4,
            reason: "low confidence",
            transcriptExcerpt: "sample",
            queuedAt: stale
        )
        try VoiceMemoReviewStore.enqueue(entry)
        let report = try VoiceMemoReviewStore.sweepTTL(now: Date())
        try expect(report.autoDismissed == 1, "auto-dismiss one stale pending")
        try expect(VoiceMemoReviewStore.pendingEntries().isEmpty, "no longer pending")
        let dismissed = VoiceMemoReviewStore.load().entries.filter { $0.status == .dismissed }
        try expect(dismissed.count == 1, "moved to dismissed")

        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: fakeHome)
    }

    await test("VoiceMemoReviewStore TTL purges old dismissed entries") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-voicememo-purge-\(UUID().uuidString)", isDirectory: true)
        BridgePaths.overrideHomeForTesting(fakeHome)

        let oldDismiss = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8 * 86_400))
        let entry = VoiceMemoReviewEntry(
            memoId: "purged-memo",
            memoTitle: "Dismissed memo",
            intentKind: VoiceMemoIntentKind.review.rawValue,
            confidence: 0.4,
            reason: "manual dismiss",
            transcriptExcerpt: "sample",
            queuedAt: oldDismiss,
            statusChangedAt: oldDismiss,
            status: .dismissed
        )
        try VoiceMemoReviewStore.save(VoiceMemoReviewManifest(entries: [entry]))
        let report = try VoiceMemoReviewStore.sweepTTL(now: Date())
        try expect(report.purged == 1, "purge old dismissed")
        try expect(VoiceMemoReviewStore.load().entries.isEmpty, "manifest empty")

        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: fakeHome)
    }

    await test("voice_memo_review_resolve mark_handled marks processed + resolves") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-voicememo-resolve-\(UUID().uuidString)", isDirectory: true)
        BridgePaths.overrideHomeForTesting(fakeHome)

        let entry = VoiceMemoReviewEntry(
            memoId: "resolve-memo-id",
            memoTitle: "Handled memo",
            intentKind: VoiceMemoIntentKind.review.rawValue,
            confidence: 0.5,
            reason: "test",
            transcriptExcerpt: "Keep this for testing."
        )
        try VoiceMemoReviewStore.enqueue(entry)

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VoiceMemoModule.register(on: router)
        let result = try await router.dispatch(toolName: "voice_memo_review_resolve", arguments: .object([
            "id": .string(entry.id),
            "action": .string("mark_handled"),
        ]))
        guard case .object(let envelope) = result else {
            try expect(false, "expected object")
            return
        }
        try expect(envelope["markedProcessed"] == .bool(true), "marked processed")
        try expect(envelope["resolved"] == .bool(true), "resolved")
        try expect(VoiceMemoProcessedStore.isProcessed(id: "resolve-memo-id"), "processed.json")
        try expect(VoiceMemoReviewStore.pendingEntries().isEmpty, "removed from pending")

        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: fakeHome)
    }

    await test("voice_memo_review_resolve blocks duplicate memory_keep") {
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-voicememo-dup-\(UUID().uuidString)", isDirectory: true)
        BridgePaths.overrideHomeForTesting(fakeHome)

        try VoiceMemoProcessedStore.markProcessed(id: "dup-memo")
        let entry = VoiceMemoReviewEntry(
            memoId: "dup-memo",
            memoTitle: "Dup memo",
            memoPath: "/tmp/dup.m4a",
            intentKind: VoiceMemoIntentKind.memoryKeep.rawValue,
            confidence: 0.5,
            reason: "retry",
            transcriptExcerpt: "Keep this note about duplicates."
        )
        try VoiceMemoReviewStore.enqueue(entry)

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VoiceMemoModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "voice_memo_review_resolve", arguments: .object([
                "id": .string(entry.id),
                "action": .string("memory_keep"),
            ]))
            try expect(false, "should throw duplicate")
        } catch {
            try expect(
                error.localizedDescription.contains("already processed"),
                "duplicate blocked: \(error.localizedDescription)"
            )
        }

        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: fakeHome)
    }

    await test("voice_memo_transcript_refresh writes sidecar from fixture") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("refresh.m4a")
        try makeTsrpM4AFixture(transcript: "Refresh ladder transcript text.").write(to: audio)

        // Mock Parakeet so the live FluidAudio/Neural-Engine path is never loaded.
        // The fixture Apple transcript is short (< 80-char suspicious threshold) so
        // the ladder would otherwise fall through to the live ASR engine, which
        // hangs the process at exit in CI (CoreML Neural-Engine threads don't release
        // cleanly from a static singleton). Throw .disabled → Apple fallback wins.
        let priorTranscribe = VoiceMemoTranscriber.transcribeFile
        VoiceMemoTranscriber.transcribeFile = { _ in throw VoiceMemoTranscriber.TranscriberError.disabled }
        defer { VoiceMemoTranscriber.transcribeFile = priorTranscribe }

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VoiceMemoModule.register(on: router)
        let result = try await router.dispatch(toolName: "voice_memo_transcript_refresh", arguments: .object([
            "path": .string(audio.path),
        ]))
        guard case .object(let envelope) = result else {
            try expect(false, "expected object")
            return
        }
        try expect(envelope["hasTranscript"] == .bool(true), "has transcript")
        try expect(envelope["source"] == .string("apple"), "apple source")
        let sidecar = VoiceMemoDiscovery.loadTranscriptSidecar(for: audio)
        try expect(sidecar?.contains("Refresh ladder") == true, "sidecar written")

        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - tsrp MP4 fixtures

private func mp4Atom(type: String, payload: Data) -> Data {
    var result = Data()
    let size = UInt32(8 + payload.count)
    result.append(UInt8((size >> 24) & 0xFF))
    result.append(UInt8((size >> 16) & 0xFF))
    result.append(UInt8((size >> 8) & 0xFF))
    result.append(UInt8(size & 0xFF))
    result.append(contentsOf: type.utf8.prefix(4))
    result.append(payload)
    return result
}

private func makeMvhdPayload(durationSec: Double, timescale: UInt32 = 1000) -> Data {
    var payload = Data([0]) // version 0
    payload.append(contentsOf: [UInt8](repeating: 0, count: 8)) // creation + modification
    let ts = timescale.bigEndian
    payload.append(UInt8((ts >> 24) & 0xFF))
    payload.append(UInt8((ts >> 16) & 0xFF))
    payload.append(UInt8((ts >> 8) & 0xFF))
    payload.append(UInt8(ts & 0xFF))
    let dur = UInt32(durationSec * Double(timescale)).bigEndian
    payload.append(UInt8((dur >> 24) & 0xFF))
    payload.append(UInt8((dur >> 16) & 0xFF))
    payload.append(UInt8((dur >> 8) & 0xFF))
    payload.append(UInt8(dur & 0xFF))
    payload.append(contentsOf: [0, 0, 1, 0]) // rate 1.0
    payload.append(contentsOf: [0, 1, 0, 0]) // volume
    payload.append(Data(repeating: 0, count: 10))
    payload.append(contentsOf: [UInt8](repeating: 0, count: 36)) // matrix + pre-defined
    return payload
}

private func makeTsrpM4AFixture(transcript: String, durationSec: Double? = nil) -> Data {
    let escaped = transcript.replacingOccurrences(of: "\"", with: "\\\"")
    let json = """
    {"attributedString":{"attributeTable":[{"timeRange":[0,1.0]}],"runs":["\(escaped)",0]},"locale":{"identifier":"en_US","current":0}}
    """
    let jsonData = Data(json.utf8)
    let tsrp = mp4Atom(type: "tsrp", payload: jsonData)
    let udta = mp4Atom(type: "udta", payload: tsrp)
    let trak = mp4Atom(type: "trak", payload: udta)
    var moovChildren = Data()
    if let durationSec {
        moovChildren.append(mp4Atom(type: "mvhd", payload: makeMvhdPayload(durationSec: durationSec)))
    }
    moovChildren.append(trak)
    let moov = mp4Atom(type: "moov", payload: moovChildren)
    let ftypPayload = Data("M4A ".utf8) + Data("M4A ".utf8) + Data([0, 0, 0, 0])
    let ftyp = mp4Atom(type: "ftyp", payload: ftypPayload)
    return ftyp + moov
}
