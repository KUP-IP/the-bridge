// MemoryHubMemoTitleTests.swift — PKT-MEM-114 P1: progressive AI memo titles
// TheBridge · Tests
//
// Pure-logic + file-backed asserts for the title floor: locale-aware humanized date,
// default-name detection, intent-led Tier-1 heuristic (elected-primary subject + `+N`
// count + transcript-hash key), the edited-pinned bounded cache, and the list-floor
// resolution (named → cached → date). Hermetic temp home for the store. Date asserts
// use contains/prefix (not ==) to survive the macOS narrow-no-break-space in `h:mm a`.

import Foundation
import MCP
import TheBridgeLib

private func withTitleTempHome<T>(_ body: () async throws -> T) async rethrows -> T {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("MemoHubTitle-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer { BridgePaths.overrideHomeForTesting(nil); try? fm.removeItem(at: tmp) }
    return try await body()
}

private func fixedCal() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal
}
private let fixedLocale = Locale(identifier: "en_US")
private func mk(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func mtitle(_ text: String, _ prov: MemoTitle.Provenance, _ at: String, hash: String? = nil, count: Int = 1) -> MemoTitle {
    MemoTitle(title: text, provenance: prov, intentCount: count, transcriptHash: hash, generatedAt: at)
}

func runMemoryHubMemoTitleTests() async {
    print("\n🏷️  Memory Hub titles — date floor + heuristic + cache (PKT-MEM-114)")

    let cal = fixedCal()
    let now = mk(cal, 2026, 6, 25, 22, 0)   // Thu Jun 25 2026, 10:00 PM

    // MARK: Humanized date floor

    await test("date_today_relativePrefix") {
        let d = mk(cal, 2026, 6, 25, 20, 30)
        let s = MemoryHubMemoTitler.humanizedDate(d, now: now, calendar: cal, locale: fixedLocale)
        try expect(s.hasPrefix("Today, "), "same day ⇒ Today: \(s)")
        try expect(s.contains("8:30") && s.contains("PM"), "carries the time: \(s)")
    }
    await test("date_yesterday_relativePrefix") {
        let d = mk(cal, 2026, 6, 24, 9, 15)
        let s = MemoryHubMemoTitler.humanizedDate(d, now: now, calendar: cal, locale: fixedLocale)
        try expect(s.hasPrefix("Yesterday, "), "prior day ⇒ Yesterday: \(s)")
        try expect(s.contains("9:15") && s.contains("AM"), "carries the time: \(s)")
    }
    await test("date_thisYear_weekdayMonthDay_noYear") {
        let d = mk(cal, 2026, 3, 10, 14, 0)
        let s = MemoryHubMemoTitler.humanizedDate(d, now: now, calendar: cal, locale: fixedLocale)
        try expect(s.contains("Mar") && s.contains("10"), "month+day: \(s)")
        try expect(s.contains("2:00"), "time: \(s)")
        try expect(!s.contains("2026"), "same year omits the year: \(s)")
    }
    await test("date_priorYear_includesYear") {
        let d = mk(cal, 2024, 11, 5, 8, 0)
        let s = MemoryHubMemoTitler.humanizedDate(d, now: now, calendar: cal, locale: fixedLocale)
        try expect(s.contains("Nov") && s.contains("2024"), "prior year shows the year: \(s)")
        try expect(s.contains("8:00"), "time: \(s)")
    }
    await test("date_neverRawId") {
        // The whole point: a timestamp filename must NOT leak through as a title.
        let d = mk(cal, 2026, 6, 25, 20, 30)
        let s = MemoryHubMemoTitler.humanizedDate(d, now: now, calendar: cal, locale: fixedLocale)
        try expect(!s.contains("20260625") && !s.contains(".m4a"), "no raw id: \(s)")
    }

    // MARK: Default-name detection

    await test("name_timestampStem_isDefault") {
        try expect(MemoryHubMemoTitler.isDefaultName("20260624 203010"), "digit-stem ⇒ default")
        try expect(MemoryHubMemoTitler.isDefaultName("2026-06-24 20:30:10"), "iso-ish ⇒ default")
        // Real on-device Apple/import auto-name: timestamp + hex id suffix (the dominant shape —
        // on-device smoke caught these leaking through as raw titles when only digits were checked).
        try expect(MemoryHubMemoTitler.isDefaultName("20260624 162727 760C66A8"), "stamp + hex id ⇒ default")
        try expect(MemoryHubMemoTitler.isDefaultName("20260301 115611 14CA8AA1"), "stamp + hex id ⇒ default")
        try expect(MemoryHubMemoTitler.isDefaultName("New Recording 3"), "Apple placeholder ⇒ default")
        try expect(MemoryHubMemoTitler.isDefaultName("   "), "blank ⇒ default")
    }
    await test("name_realName_isNotDefault") {
        try expect(!MemoryHubMemoTitler.isDefaultName("Bridge RT1"), "user name ⇒ honored")
        try expect(!MemoryHubMemoTitler.isDefaultName("Jacob sync notes"), "user name ⇒ honored")
        // A user-given name that merely begins with a date must NOT be eaten by the stamp rule.
        try expect(!MemoryHubMemoTitler.isDefaultName("20260624 standup with Bob"), "date prefix + words ⇒ real name")
    }

    // MARK: Tier-1 intent-led heuristic

    await test("heuristic_reminderPrimary_leadsWithReminderSubject") {
        let plan = VoiceMemoPlan(generatedTitle: "Voice memo", skipMemoryKeep: false,
                                 summary: "a long rambling summary that should not be the title",
                                 actions: [],
                                 intents: [VoiceMemoIntent(kind: .reminder, confidence: 0.95,
                                                           title: "Send Jacob the Phase 0 results")])
        let t = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "remind me…", now: now)
        try expect(t.provenance == .heuristic, "heuristic provenance")
        try expect(t.title == "Send Jacob the Phase 0 results", "leads with the reminder subject: \(t.title)")
        try expect(t.transcriptHash?.isEmpty == false, "carries a transcript hash for invalidation")
    }
    await test("heuristic_multiIntent_primaryIsReminder_countIsThree") {
        let plan = VoiceMemoPlan(generatedTitle: "Voice memo", skipMemoryKeep: false, summary: "s", actions: [],
            intents: [
                VoiceMemoIntent(kind: .registryUpdate, confidence: 0.99, entityKey: "project", entityHint: "Bridge v4", fields: ["summary": "shipped trust fixes"]),
                VoiceMemoIntent(kind: .reminder, confidence: 0.80, title: "Send Jacob results"),
                VoiceMemoIntent(kind: .memoryKeep, confidence: 0.90, title: "prefer adversarial reviews"),
            ])
        let t = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "x", now: now)
        try expect(t.title == "Send Jacob results", "lane-priority-first: reminder wins even at lower confidence: \(t.title)")
        try expect(t.intentCount == 3, "+N counts all executable lanes (got \(t.intentCount))")
    }
    await test("heuristic_registryPrimary_entityDashGist") {
        let plan = VoiceMemoPlan(generatedTitle: "Voice memo", skipMemoryKeep: false, summary: "fallback", actions: [],
            intents: [VoiceMemoIntent(kind: .registryUpdate, confidence: 0.95, entityKey: "project",
                                      entityHint: "Bridge v4", fields: ["summary": "shipped the trust fixes"])])
        let t = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "x", now: now)
        try expect(t.title.hasPrefix("Bridge v4 —"), "entity leads: \(t.title)")
        try expect(t.title.contains("shipped"), "gist follows: \(t.title)")
    }
    await test("heuristic_longSubject_cappedWithEllipsis") {
        let long = "send jacob the full phase zero adversarial review results before the end of day"
        let plan = VoiceMemoPlan(generatedTitle: "g", skipMemoryKeep: false, summary: "s", actions: [],
            intents: [VoiceMemoIntent(kind: .reminder, confidence: 0.95, title: long)])
        let t = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "x", now: now)
        try expect(t.title.hasSuffix("…"), "capped subject ends with ellipsis: \(t.title)")
        try expect(t.title.split(separator: " ").count <= 9, "≤ 8 words + ellipsis token: \(t.title)")
    }
    await test("heuristic_hash_stableAndContentKeyed") {
        let plan = VoiceMemoPlan(generatedTitle: "g", skipMemoryKeep: false, summary: "s", actions: [],
            intents: [VoiceMemoIntent(kind: .reminder, confidence: 0.95, title: "x")])
        let a = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "  hello world ", now: now)
        let b = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "hello world", now: now)
        let c = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "different transcript", now: now)
        try expect(a.transcriptHash == b.transcriptHash, "trim-normalized ⇒ same hash")
        try expect(a.transcriptHash != c.transcriptHash, "different transcript ⇒ different hash")
    }

    // MARK: Cache store — edited-pin, round-trip, prune

    await test("store_putGetRoundTrip") {
        try await withTitleTempHome {
            let t = mtitle("Send Jacob results", .heuristic, "2026-06-25T10:00:00Z", hash: "h1")
            MemoryHubMemoTitleStore.put(t, memoId: "m1")
            try expect(MemoryHubMemoTitleStore.title(for: "m1") == t, "round-trips")
            try expect(MemoryHubMemoTitleStore.title(for: "absent") == nil, "miss ⇒ nil")
        }
    }
    await test("store_editedPin_autoNeverOverwrites") {
        try await withTitleTempHome {
            MemoryHubMemoTitleStore.put(mtitle("My title", .edited, "2026-06-25T10:00:00Z"), memoId: "m1")
            // A later auto title (heuristic/local/cloud) must NOT clobber the human edit.
            MemoryHubMemoTitleStore.put(mtitle("auto guess", .heuristic, "2026-06-25T11:00:00Z"), memoId: "m1")
            let got = MemoryHubMemoTitleStore.title(for: "m1")
            try expect(got?.title == "My title" && got?.provenance == .edited, "edit survives auto: \(String(describing: got))")
        }
    }
    await test("store_editedOverwritesEdited") {
        try await withTitleTempHome {
            MemoryHubMemoTitleStore.put(mtitle("First", .edited, "2026-06-25T10:00:00Z"), memoId: "m1")
            MemoryHubMemoTitleStore.put(mtitle("Second", .edited, "2026-06-25T12:00:00Z"), memoId: "m1")
            try expect(MemoryHubMemoTitleStore.title(for: "m1")?.title == "Second", "a new edit replaces the old")
        }
    }
    await test("store_remove") {
        try await withTitleTempHome {
            MemoryHubMemoTitleStore.put(mtitle("x", .heuristic, "2026-06-25T10:00:00Z"), memoId: "m1")
            MemoryHubMemoTitleStore.remove(memoId: "m1")
            try expect(MemoryHubMemoTitleStore.title(for: "m1") == nil, "removed")
        }
    }
    await test("store_prune_keepsNewestAutos_andAllEdited") {
        // 3 autos + 1 edited, cap 2 ⇒ keep the edited (always) + the single newest auto.
        var all: [String: MemoTitle] = [
            "a": mtitle("a", .heuristic, "2026-06-25T08:00:00Z"),
            "b": mtitle("b", .heuristic, "2026-06-25T09:00:00Z"),
            "c": mtitle("c", .heuristic, "2026-06-25T10:00:00Z"),
            "e": mtitle("e", .edited, "2026-01-01T00:00:00Z"),
        ]
        all = MemoryHubMemoTitleStore.prune(all, max: 2)
        try expect(all["e"] != nil, "edited is always retained even past the cap")
        try expect(all["c"] != nil, "newest auto kept")
        try expect(all["a"] == nil && all["b"] == nil, "older autos pruned (kept \(all.keys.sorted()))")
    }

    // MARK: List-floor resolution

    await test("listDisplay_namedRecording_honored") {
        let rec = VoiceMemoRecording(id: "m1", path: "/x", title: "Bridge RT1", recordedAt: now, transcript: nil)
        let d = MemoryHubMemoTitler.listDisplay(recording: rec, cached: nil, now: now)
        try expect(d.text == "Bridge RT1" && d.provenance == .named, "real name wins")
        try expect(!d.isPlaceholder, "a real name is not a placeholder")
    }
    await test("listDisplay_defaultName_usesCachedWhenPresent") {
        let rec = VoiceMemoRecording(id: "m1", path: "/x", title: "20260625 203010", recordedAt: now, transcript: nil)
        let cached = mtitle("Send Jacob results", .heuristic, "2026-06-25T10:00:00Z", count: 2)
        let d = MemoryHubMemoTitler.listDisplay(recording: rec, cached: cached, now: now)
        try expect(d.text == "Send Jacob results" && d.provenance == .heuristic, "cached title shown")
        try expect(d.intentCount == 2 && !d.isPlaceholder, "carries +N, not a placeholder")
    }
    await test("listDisplay_defaultName_noCache_dateFloor") {
        let rec = VoiceMemoRecording(id: "m1", path: "/x", title: "20260625 203010", recordedAt: mk(cal, 2026, 6, 25, 20, 30), transcript: nil)
        let d = MemoryHubMemoTitler.listDisplay(recording: rec, cached: nil, now: now)
        try expect(d.isPlaceholder && d.provenance == .placeholder, "no title yet ⇒ muted date floor")
        try expect(!d.text.contains("20260625"), "floor is humanized, never the raw stem: \(d.text)")
    }

    // MARK: P2 — generate-on-select + Inbox resolution (cockpit list + Inbox surfaces)

    await test("selectThenList_heuristicCached_beatsDateFloor") {
        // Generate-on-select semantics: a default-named recording shows the date floor until
        // selection caches the Tier-1 heuristic; thereafter the list resolves to that title.
        try await withTitleTempHome {
            let rec = VoiceMemoRecording(id: "m1", path: "/x", title: "20260625 203010",
                                         recordedAt: mk(cal, 2026, 6, 25, 20, 30), transcript: nil)
            // Before selection: no cache ⇒ muted date floor.
            let before = MemoryHubMemoTitler.listDisplay(recording: rec, cached: MemoryHubMemoTitleStore.title(for: "m1"), now: now)
            try expect(before.isPlaceholder, "no cache yet ⇒ date floor")

            // On select: generate + cache the heuristic (as the cockpit's loadPreview does).
            let plan = VoiceMemoPlan(generatedTitle: "Voice memo", skipMemoryKeep: false, summary: "s", actions: [],
                intents: [VoiceMemoIntent(kind: .reminder, confidence: 0.95, title: "Send Jacob results")])
            let t = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "remind me…", now: now)
            MemoryHubMemoTitleStore.put(t, memoId: "m1")

            // After selection: the list resolves to the cached heuristic, not the floor.
            let after = MemoryHubMemoTitler.listDisplay(recording: rec, cached: MemoryHubMemoTitleStore.title(for: "m1"), now: now)
            try expect(!after.isPlaceholder, "cached ⇒ no longer a placeholder")
            try expect(after.text == "Send Jacob results" && after.provenance == .heuristic, "shows the heuristic: \(after.text)")
        }
    }
    await test("selectThenList_editedRename_survivesGenerateOnSelect") {
        // A prior human rename must NOT be clobbered when select regenerates the heuristic.
        try await withTitleTempHome {
            MemoryHubMemoTitleStore.put(mtitle("My own title", .edited, "2026-06-25T09:00:00Z"), memoId: "m1")
            let plan = VoiceMemoPlan(generatedTitle: "g", skipMemoryKeep: false, summary: "s", actions: [],
                intents: [VoiceMemoIntent(kind: .reminder, confidence: 0.95, title: "auto guess")])
            MemoryHubMemoTitleStore.put(MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "x", now: now), memoId: "m1")
            let got = MemoryHubMemoTitleStore.title(for: "m1")
            try expect(got?.title == "My own title" && got?.provenance == .edited, "edit survives select: \(String(describing: got))")
        }
    }
    await test("inboxResolution_cachedTitleWins_elseFallsBackToEntry") {
        // The Inbox is a read-only consumer: the cache wins, an absent entry falls back to memoTitle.
        try await withTitleTempHome {
            MemoryHubMemoTitleStore.put(mtitle("Send Jacob results", .heuristic, "2026-06-25T10:00:00Z"), memoId: "cached")
            let cachedResolved = MemoryHubMemoTitleStore.title(for: "cached")?.title ?? "20260625 203010"
            try expect(cachedResolved == "Send Jacob results", "cached intent-led title wins over the raw stem")

            let fallbackResolved = MemoryHubMemoTitleStore.title(for: "absent")?.title ?? "Stored entry title"
            try expect(fallbackResolved == "Stored entry title", "no cache ⇒ falls back to the entry's memoTitle")
        }
    }

    // MARK: P3a — Tier-2 local (Ollama) gating + edited-pin + idle sweep

    await runMemoryHubMemoTitleP3aTests(cal: cal, now: now)
    await runMemoryHubMemoTitleP3bTests(cal: cal, now: now)
    await runMemoryHubMemoTitleReviewRemediationTests(cal: cal, now: now)

    // MARK: Freshness / invalidation

    await test("freshness_hashMatch_andListNilCurrent") {
        let t = mtitle("x", .heuristic, "2026-06-25T10:00:00Z", hash: "H")
        try expect(t.isFresh(forTranscriptHash: "H"), "same hash ⇒ fresh")
        try expect(!t.isFresh(forTranscriptHash: "H2"), "changed transcript ⇒ stale")
        try expect(t.isFresh(forTranscriptHash: nil), "list has no transcript ⇒ treat as fresh (rebuilt on select)")
        let named = mtitle("Bridge RT1", .named, "2026-06-25T10:00:00Z", hash: nil)
        try expect(named.isFresh(forTranscriptHash: "anything"), "name titles have no hash ⇒ always fresh")
    }
}

// MARK: - P3a: Tier-2 Ollama titles + local-first idle sweep -------------------------------

/// Injected local-title LLM stub — never touches a real Ollama. Returns a canned candidate
/// (or nil to simulate failure/timeout) and records whether it was invoked.
private final class StubLocalTitleLLM: MemoryHubMemoTitler.LocalTitleLLM, @unchecked Sendable {
    let candidate: String?
    private(set) var called = false
    init(candidate: String?) { self.candidate = candidate }
    func titleCandidate(transcript: String, fallbackTitle: String) async -> String? {
        called = true
        return candidate
    }
}

/// Snapshot + restore the UserDefaults keys the Tier-2 gate reads, so a test can force the
/// flag ON/OFF deterministically regardless of seeded first-run defaults.
private func withOllamaTitleFlags<T>(enabled: Bool, _ body: () async throws -> T) async rethrows -> T {
    let d = UserDefaults.standard
    let routingKey = BridgeDefaults.voiceMemoOllamaRouting
    let modeKey = BridgeDefaults.voiceMemoCuratorMode
    let modelKey = BridgeDefaults.ollamaSummarizationModel
    let priorRouting = d.object(forKey: routingKey)
    let priorMode = d.object(forKey: modeKey)
    let priorModel = d.object(forKey: modelKey)
    defer {
        if let priorRouting { d.set(priorRouting, forKey: routingKey) } else { d.removeObject(forKey: routingKey) }
        if let priorMode { d.set(priorMode, forKey: modeKey) } else { d.removeObject(forKey: modeKey) }
        if let priorModel { d.set(priorModel, forKey: modelKey) } else { d.removeObject(forKey: modelKey) }
    }
    if enabled {
        d.set(true, forKey: routingKey)
        d.set(VoiceMemoCuratorMode.auto.rawValue, forKey: modeKey)
        d.set("gemma4:12b", forKey: modelKey)
    } else {
        // `.heuristics` forces shouldUseLocalOllama() == false regardless of the routing flag.
        d.set(VoiceMemoCuratorMode.heuristics.rawValue, forKey: modeKey)
    }
    return try await body()
}

private func snapIntent(_ id: String, _ kind: String, _ conf: Double,
                        entityKey: String? = nil, entityHint: String? = nil,
                        title: String? = nil, fields: [String: String] = [:], demoted: Bool = false) -> PlanSnapshotIntent {
    PlanSnapshotIntent(intentId: id, kind: kind, confidence: conf, entityKey: entityKey,
                       entityHint: entityHint, title: title, fields: fields, demoted: demoted)
}

func runMemoryHubMemoTitleP3aTests(cal: Calendar, now: Date) async {
    print("\n🏷️  Memory Hub titles — P3a Tier-2 Ollama + idle sweep (PKT-MEM-114)")

    // MARK: Tier-2 gating

    await test("p3a_gate_off_noLocalTitleProduced") {
        try await withTitleTempHome {
            try await withOllamaTitleFlags(enabled: false) {
                try expect(!MemoryHubMemoTitler.localTitleEnabled(), "flag OFF ⇒ gate closed")
                let stub = StubLocalTitleLLM(candidate: "Should Not Be Used")
                MemoryHubMemoTitler.localTitleLLMOverride = stub
                defer { MemoryHubMemoTitler.localTitleLLMOverride = nil }
                let out = await MemoryHubMemoTitler.enhanceWithLocalTitle(
                    memoId: "m1", transcript: "remind me to call Jacob", fallbackTitle: "Call Jacob", now: now)
                try expect(out == nil, "disabled ⇒ no upgrade returned")
                try expect(!stub.called, "disabled ⇒ the LLM is never even invoked")
                try expect(MemoryHubMemoTitleStore.title(for: "m1") == nil, "no .local cached when off")
            }
        }
    }

    await test("p3a_gate_on_cachesLocalProvenance") {
        try await withTitleTempHome {
            try await withOllamaTitleFlags(enabled: true) {
                try expect(MemoryHubMemoTitler.localTitleEnabled(), "flag ON + model ⇒ gate open")
                let stub = StubLocalTitleLLM(candidate: "Ship Bridge v4 Trust Fixes")
                MemoryHubMemoTitler.localTitleLLMOverride = stub
                defer { MemoryHubMemoTitler.localTitleLLMOverride = nil }
                let out = await MemoryHubMemoTitler.enhanceWithLocalTitle(
                    memoId: "m1", transcript: "we shipped the trust fixes for bridge v4 today",
                    fallbackTitle: "Bridge v4", now: now)
                try expect(stub.called, "enabled ⇒ the LLM is invoked")
                try expect(out?.provenance == .local, "cached as .local provenance: \(String(describing: out))")
                try expect(out?.title == "Ship Bridge v4 Trust Fixes", "cleaned candidate: \(String(describing: out?.title))")
                try expect(out?.transcriptHash?.isEmpty == false, "carries a transcript hash for invalidation")
                try expect(MemoryHubMemoTitleStore.title(for: "m1")?.provenance == .local, "persisted to the cache")
            }
        }
    }

    await test("p3a_localDoesNotOverwriteEdited") {
        try await withTitleTempHome {
            try await withOllamaTitleFlags(enabled: true) {
                // A human rename is pinned: a later Tier-2 .local title must NOT clobber it.
                MemoryHubMemoTitleStore.put(mtitle("My own title", .edited, "2026-06-25T09:00:00Z"), memoId: "m1")
                MemoryHubMemoTitler.localTitleLLMOverride = StubLocalTitleLLM(candidate: "Auto Local Guess")
                defer { MemoryHubMemoTitler.localTitleLLMOverride = nil }
                _ = await MemoryHubMemoTitler.enhanceWithLocalTitle(
                    memoId: "m1", transcript: "some transcript", fallbackTitle: "fallback", now: now)
                let got = MemoryHubMemoTitleStore.title(for: "m1")
                try expect(got?.title == "My own title" && got?.provenance == .edited,
                           "edit survives the Tier-2 upgrade: \(String(describing: got))")
            }
        }
    }

    await test("p3a_emptyOrFallbackCandidate_keepsHeuristic") {
        try await withTitleTempHome {
            try await withOllamaTitleFlags(enabled: true) {
                // nil candidate (failure/timeout) ⇒ no write.
                MemoryHubMemoTitler.localTitleLLMOverride = StubLocalTitleLLM(candidate: nil)
                let a = await MemoryHubMemoTitler.enhanceWithLocalTitle(
                    memoId: "m1", transcript: "t", fallbackTitle: "Heuristic Title", now: now)
                try expect(a == nil && MemoryHubMemoTitleStore.title(for: "m1") == nil, "nil candidate ⇒ no .local")
                // A candidate identical to the fallback is rejected (no value added).
                MemoryHubMemoTitler.localTitleLLMOverride = StubLocalTitleLLM(candidate: "Heuristic Title")
                defer { MemoryHubMemoTitler.localTitleLLMOverride = nil }
                let b = await MemoryHubMemoTitler.enhanceWithLocalTitle(
                    memoId: "m1", transcript: "t", fallbackTitle: "Heuristic Title", now: now)
                try expect(b == nil && MemoryHubMemoTitleStore.title(for: "m1") == nil, "fallback-equal ⇒ no .local")
            }
        }
    }

    // MARK: Snapshot-derived heuristic (sweep input)

    await test("p3a_snapshotHeuristic_intentLed_excludesDemoted") {
        let snap = PlanSnapshot(memoId: "m1", provenance: .heuristic, version: 1,
                                createdAt: "2026-06-25T10:00:00Z",
                                intents: [
                                    snapIntent("i1", "registry_update", 0.99, entityKey: "project",
                                               entityHint: "Bridge v4", fields: ["summary": "shipped trust fixes"]),
                                    snapIntent("i2", "reminder", 0.80, title: "Send Jacob results"),
                                    snapIntent("i3", "memory_keep", 0.90, title: "prefer adversarial reviews", demoted: true),
                                ])
        let t = MemoryHubMemoTitler.heuristicTitle(snapshot: snap, now: now)
        try expect(t.provenance == .heuristic, "heuristic provenance")
        try expect(t.title == "Send Jacob results", "lane-priority-first reminder wins: \(t.title)")
        try expect(t.intentCount == 2, "demoted lane excluded from +N (got \(t.intentCount))")
        try expect(t.transcriptHash == nil, "snapshot-derived ⇒ no transcript hash (upgradeable on select)")
    }

    // MARK: Idle sweep

    await test("p3a_sweep_emptyCache_cachesHeuristicFromSnapshot") {
        try await withTitleTempHome {
            let snap = PlanSnapshot(memoId: "sweep-1", provenance: .heuristic, version: 1,
                                    createdAt: "2026-06-25T10:00:00Z",
                                    intents: [snapIntent("i1", "reminder", 0.95, title: "Email the Q3 report")])
            _ = try MemoryHubPlanSnapshotStore.append(snap)
            let n = MemoryHubMemoTitler.launchSweep(now: now)
            try expect(n == 1, "one memo titled (got \(n))")
            let got = MemoryHubMemoTitleStore.title(for: "sweep-1")
            try expect(got?.title == "Email the Q3 report" && got?.provenance == .heuristic,
                       "sweep cached the snapshot heuristic: \(String(describing: got))")
        }
    }

    await test("p3a_sweep_leavesEditedAndExistingTitles") {
        try await withTitleTempHome {
            // memo A: a pinned human edit — sweep must leave it.
            let snapA = PlanSnapshot(memoId: "A", provenance: .heuristic, version: 1, createdAt: "2026-06-25T10:00:00Z",
                                     intents: [snapIntent("i1", "reminder", 0.95, title: "Auto would say this")])
            _ = try MemoryHubPlanSnapshotStore.append(snapA)
            MemoryHubMemoTitleStore.put(mtitle("Human kept this", .edited, "2026-06-25T09:00:00Z"), memoId: "A")
            // memo B: already has a fresh heuristic title — sweep must not rewrite it.
            let snapB = PlanSnapshot(memoId: "B", provenance: .heuristic, version: 1, createdAt: "2026-06-25T10:00:00Z",
                                     intents: [snapIntent("i1", "reminder", 0.95, title: "Snapshot title B")])
            _ = try MemoryHubPlanSnapshotStore.append(snapB)
            MemoryHubMemoTitleStore.put(mtitle("Existing local B", .local, "2026-06-25T11:00:00Z", hash: "h"), memoId: "B")

            let n = MemoryHubMemoTitler.launchSweep(now: now)
            try expect(n == 0, "nothing to do — both already titled (wrote \(n))")
            try expect(MemoryHubMemoTitleStore.title(for: "A")?.provenance == .edited, "edit preserved")
            try expect(MemoryHubMemoTitleStore.title(for: "B")?.title == "Existing local B", "existing local preserved")
        }
    }

    await test("p3a_sweep_capHolds") {
        try await withTitleTempHome {
            for i in 0..<5 {
                let snap = PlanSnapshot(memoId: "cap-\(i)", provenance: .heuristic, version: 1,
                                        createdAt: "2026-06-25T10:00:00Z",
                                        intents: [snapIntent("i1", "reminder", 0.95, title: "Title \(i)")])
                _ = try MemoryHubPlanSnapshotStore.append(snap)
            }
            let n = MemoryHubMemoTitler.launchSweep(now: now, cap: 2)
            try expect(n == 2, "per-sweep cap holds (wrote \(n))")
            let titled = (0..<5).filter { MemoryHubMemoTitleStore.title(for: "cap-\($0)") != nil }.count
            try expect(titled == 2, "exactly cap memos titled this pass (got \(titled))")
        }
    }
}

// MARK: - P3b: operator rename override + manual Tier-3 cloud title -------------------------

/// Injected cloud chat transport stub — never opens a socket. Either returns a canned
/// `(Data, HTTPURLResponse)` with a chosen status code, or throws to simulate a network
/// failure/timeout. Records the last request so a test can assert headers/body/url.
private final class StubCloudTransport: CloudChatTransport, @unchecked Sendable {
    let status: Int
    let payload: Data
    let throwError: Error?
    private(set) var lastRequest: URLRequest?

    init(status: Int = 200, json: String = "", throwError: Error? = nil) {
        self.status = status
        self.payload = Data(json.utf8)
        self.throwError = throwError
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        if let throwError { throw throwError }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        return (payload, response)
    }
}

/// A fully-runnable cloud provider (enabled + model + valid base URL) ⇒ `canRunCloud == true`.
private func runnableProvider(model: String = "gpt-4o-mini") -> MemoryHubProvider {
    MemoryHubProvider(id: MemoryHubProviderConfigStore.openAICompatibleId,
                      baseURL: MemoryHubProviderConfigStore.defaultBaseURL,
                      model: model, enabled: true)
}

/// A canned OpenAI-compatible chat-completions body carrying one choice with `content`.
private func chatCompletionJSON(_ content: String) -> String {
    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}"
}

func runMemoryHubMemoTitleP3bTests(cal: Calendar, now: Date) async {
    print("\n🏷️  Memory Hub titles — P3b rename override + manual cloud (PKT-MEM-114)")

    // MARK: (a) Operator rename override precedence

    await test("p3b_rename_writesEdited_andAutoNeverOverwrites") {
        try await withTitleTempHome {
            // Operator rename → .edited (this mirrors the cockpit saveRename path).
            let edited = mtitle("Quarterly board deck", .edited,
                                ISO8601DateFormatter().string(from: now), hash: "h1", count: 2)
            MemoryHubMemoTitleStore.put(edited, memoId: "m1")
            let afterRename = MemoryHubMemoTitleStore.title(for: "m1")
            try expect(afterRename?.provenance == .edited && afterRename?.title == "Quarterly board deck",
                       "rename writes .edited: \(String(describing: afterRename))")
            try expect(afterRename?.intentCount == 2, "rename carries the prior +N count")

            // A later heuristic / .local / .cloud put() must NOT overwrite the human edit.
            MemoryHubMemoTitleStore.put(mtitle("auto heuristic", .heuristic, "2026-06-26T01:00:00Z"), memoId: "m1")
            MemoryHubMemoTitleStore.put(mtitle("auto local", .local, "2026-06-26T02:00:00Z"), memoId: "m1")
            MemoryHubMemoTitleStore.put(mtitle("auto cloud", .cloud, "2026-06-26T03:00:00Z"), memoId: "m1")
            let got = MemoryHubMemoTitleStore.title(for: "m1")
            try expect(got?.provenance == .edited && got?.title == "Quarterly board deck",
                       "edit survives every later auto tier: \(String(describing: got))")
        }
    }

    await test("p3b_rename_emptyOrWhitespace_isNoOp") {
        // The cockpit guards empty/whitespace renames before put(); assert nothing is stored.
        let trimmedEmpty = "   \n  ".trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(trimmedEmpty.isEmpty, "whitespace-only rename trims to empty ⇒ guarded no-op")
    }

    // MARK: (b) Tier-3 cloud helper — success / sanitize / failure modes

    await test("p3b_cloud_success_cachesCloudProvenance_andSanitizes") {
        try await withTitleTempHome {
            // Canned completion is quoted + over-long: the helper must strip quotes and cap to ≤8 words.
            let stub = StubCloudTransport(status: 200,
                json: chatCompletionJSON("\"Ship Bridge v4 trust fixes before the end of the week\""))
            let out = try await MemoryHubCloudTitler.improve(
                memoId: "m1", transcript: "we shipped the trust fixes for bridge v4",
                provider: runnableProvider(), now: now,
                keyProvider: { "sk-test-123" }, transport: stub)
            try expect(out.provenance == .cloud, "cached as .cloud: \(out.provenance)")
            try expect(out.title.split(separator: " ").count <= 9, "≤8 words + ellipsis token: \(out.title)")
            try expect(!out.title.contains("\""), "surrounding quotes stripped: \(out.title)")
            try expect(out.transcriptHash?.isEmpty == false, "carries a transcript hash for invalidation")
            try expect(MemoryHubMemoTitleStore.title(for: "m1")?.provenance == .cloud, "persisted to the cache")
        }
    }

    await test("p3b_cloud_sendsBearerAuthAndChatCompletionsPath") {
        try await withTitleTempHome {
            let stub = StubCloudTransport(status: 200, json: chatCompletionJSON("Concise Title"))
            _ = try await MemoryHubCloudTitler.improve(
                memoId: "m1", transcript: "transcript body", provider: runnableProvider(), now: now,
                keyProvider: { "sk-secret" }, transport: stub)
            let req = stub.lastRequest
            try expect(req?.httpMethod == "POST", "POST request")
            try expect(req?.url?.absoluteString.hasSuffix("/chat/completions") == true,
                       "targets /chat/completions: \(String(describing: req?.url?.absoluteString))")
            try expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret", "bearer auth header")
            try expect(req?.timeoutInterval == MemoryHubPreview.cloudTimeoutSeconds, "bounded by the 20s cloud timeout")
            // Body carries the model + the concise-title system prompt (no key in the body).
            let body = req?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            try expect(body.contains("gpt-4o-mini"), "request body carries the provider model")
            try expect(body.contains("intent-led title"), "request body carries the concise-title system prompt")
            try expect(!body.contains("sk-secret"), "the key is the header only — never in the body")
        }
    }

    await test("p3b_cloud_nonSuccess_throwsHttpStatus_keepsPriorTitle_noReview") {
        try await withTitleTempHome {
            // A prior heuristic exists; a non-2xx cloud attempt must keep it (and queue no review).
            MemoryHubMemoTitleStore.put(mtitle("Heuristic title", .heuristic, "2026-06-25T10:00:00Z", hash: "h0", count: 1), memoId: "m1")
            let stub = StubCloudTransport(status: 429, json: "{\"error\":\"rate_limited\"}")
            var threw = false
            do {
                _ = try await MemoryHubCloudTitler.improve(
                    memoId: "m1", transcript: "t", provider: runnableProvider(), now: now,
                    keyProvider: { "sk-test" }, transport: stub)
            } catch let err as MemoryHubCloudTitler.CloudTitleError {
                threw = true
                try expect(err == .httpStatus(429), "surfaces the non-2xx status: \(err)")
            }
            try expect(threw, "non-2xx ⇒ throws (caller swallows + keeps the title)")
            let got = MemoryHubMemoTitleStore.title(for: "m1")
            try expect(got?.provenance == .heuristic && got?.title == "Heuristic title",
                       "prior title untouched on failure: \(String(describing: got))")
        }
    }

    await test("p3b_cloud_transportThrows_timeout_keepsPriorTitle") {
        try await withTitleTempHome {
            MemoryHubMemoTitleStore.put(mtitle("Heuristic title", .heuristic, "2026-06-25T10:00:00Z"), memoId: "m1")
            // Simulate a timeout/network failure: the transport throws.
            let stub = StubCloudTransport(throwError: URLError(.timedOut))
            var threw = false
            do {
                _ = try await MemoryHubCloudTitler.improve(
                    memoId: "m1", transcript: "t", provider: runnableProvider(), now: now,
                    keyProvider: { "sk-test" }, transport: stub)
            } catch { threw = true }
            try expect(threw, "transport failure propagates so the caller keeps the title")
            try expect(MemoryHubMemoTitleStore.title(for: "m1")?.provenance == .heuristic,
                       "timeout ⇒ prior title kept, no .cloud written")
        }
    }

    await test("p3b_cloud_emptyChoices_throwsEmptyCompletion") {
        try await withTitleTempHome {
            let stub = StubCloudTransport(status: 200, json: "{\"choices\":[]}")
            var threw = false
            do {
                _ = try await MemoryHubCloudTitler.improve(
                    memoId: "m1", transcript: "t", provider: runnableProvider(), now: now,
                    keyProvider: { "sk-test" }, transport: stub)
            } catch let err as MemoryHubCloudTitler.CloudTitleError {
                threw = (err == .emptyCompletion)
            }
            try expect(threw, "2xx with no usable content ⇒ emptyCompletion (keep the title)")
            try expect(MemoryHubMemoTitleStore.title(for: "m1") == nil, "nothing cached on empty completion")
        }
    }

    await test("p3b_cloud_neverOverwritesEdited") {
        try await withTitleTempHome {
            // A human rename is pinned: even a successful cloud title must NOT clobber it.
            MemoryHubMemoTitleStore.put(mtitle("My own title", .edited, "2026-06-25T09:00:00Z"), memoId: "m1")
            let stub = StubCloudTransport(status: 200, json: chatCompletionJSON("Cloud Suggested Title"))
            let out = try await MemoryHubCloudTitler.improve(
                memoId: "m1", transcript: "t", provider: runnableProvider(), now: now,
                keyProvider: { "sk-test" }, transport: stub)
            // improve() returns the STORED title (edited-pinned), so the edit is what survives.
            try expect(out.provenance == .edited && out.title == "My own title",
                       "cloud put() is edited-pinned: \(out.title)")
            try expect(MemoryHubMemoTitleStore.title(for: "m1")?.provenance == .edited, "edit survives the cloud upgrade")
        }
    }

    await test("p3b_cloud_missingKey_throwsMissingKey") {
        try await withTitleTempHome {
            let stub = StubCloudTransport(status: 200, json: chatCompletionJSON("Title"))
            var threw = false
            do {
                _ = try await MemoryHubCloudTitler.improve(
                    memoId: "m1", transcript: "t", provider: runnableProvider(), now: now,
                    keyProvider: { "   " }, transport: stub)   // blank key
            } catch let err as MemoryHubCloudTitler.CloudTitleError {
                threw = (err == .missingKey)
            }
            try expect(threw, "no key ⇒ missingKey before any network attempt")
            try expect(stub.lastRequest == nil, "the transport is never invoked without a key")
        }
    }

    // MARK: (c) canRunCloud gating — the button-enabled predicate

    await test("p3b_canRunCloud_gating") {
        // The cockpit shows/enables the cloud button ONLY when canRunCloud is true.
        let runnable = runnableProvider()
        try expect(MemoryHubProviderConfigStore.canRunCloud(runnable), "enabled + model + valid URL ⇒ runnable")

        var disabled = runnable; disabled.enabled = false
        try expect(!MemoryHubProviderConfigStore.canRunCloud(disabled), "disabled ⇒ not runnable (button hidden)")

        var noModel = runnable; noModel.model = "   "
        try expect(!MemoryHubProviderConfigStore.canRunCloud(noModel), "blank model ⇒ not runnable")

        var badURL = runnable; badURL.baseURL = "not a url"
        try expect(!MemoryHubProviderConfigStore.canRunCloud(badURL), "malformed base URL ⇒ not runnable")
    }

    await test("p3b_cloud_notRunnableProvider_throwsBeforeNetwork") {
        try await withTitleTempHome {
            var disabled = runnableProvider(); disabled.enabled = false
            let stub = StubCloudTransport(status: 200, json: chatCompletionJSON("Title"))
            var threw = false
            do {
                _ = try await MemoryHubCloudTitler.improve(
                    memoId: "m1", transcript: "t", provider: disabled, now: now,
                    keyProvider: { "sk-test" }, transport: stub)
            } catch let err as MemoryHubCloudTitler.CloudTitleError {
                threw = (err == .notRunnable)
            }
            try expect(threw, "a non-runnable provider ⇒ notRunnable, no network")
            try expect(stub.lastRequest == nil, "the transport is never invoked when not runnable")
        }
    }
}

// MARK: - Review remediation (PKT-MEM-114) — char-ceiling + sweep single-write -------------

func runMemoryHubMemoTitleReviewRemediationTests(cal: Calendar, now: Date) async {
    print("\n🏷️  Memory Hub titles — review remediation (char ceiling + sweep write)")

    // MARK: Finding 1 — character ceiling on the heuristic (CJK / long no-whitespace token)

    await test("remediation_heuristic_cjkNoWhitespace_charCapped") {
        // A long CJK string has NO whitespace separators ⇒ split-on-whitespace yields ONE
        // "word", so prefix(8 words) keeps it whole. Without a char ceiling the entire field
        // would persist verbatim into memo-titles.json (privacy parity with the 120-char
        // activity-log excerpt cap). 200 CJK chars, no spaces:
        let longCJK = String(repeating: "中", count: 200)
        let plan = VoiceMemoPlan(generatedTitle: "g", skipMemoryKeep: false, summary: "s", actions: [],
            intents: [VoiceMemoIntent(kind: .reminder, confidence: 0.95, title: longCJK)])
        let t = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "x", now: now)
        // Title is bounded (≤ cap + the single ellipsis char), NOT the full 200-char field.
        try expect(t.title.count <= 121, "char-capped (≤120 + ellipsis), got \(t.title.count): \(t.title)")
        try expect(t.title.hasSuffix("…"), "truncated title carries the ellipsis: \(t.title)")
    }

    await test("remediation_heuristic_longURLToken_charCapped") {
        // A single long token (URL / base64 / id) is also one whitespace-split "word".
        let longToken = "https://example.com/" + String(repeating: "a", count: 300)
        let plan = VoiceMemoPlan(generatedTitle: "g", skipMemoryKeep: false, summary: "s", actions: [],
            intents: [VoiceMemoIntent(kind: .reminder, confidence: 0.95, title: longToken)])
        let t = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "x", now: now)
        try expect(t.title.count <= 121, "long single-token title is char-capped, got \(t.title.count)")
    }

    await test("remediation_shortMultiword_unchanged_noFalseEllipsis") {
        // Regression guard: a short, normal space-separated title must NOT gain an ellipsis or
        // get clipped by the new char ceiling. Driven via the public heuristic entry point.
        let plan = VoiceMemoPlan(generatedTitle: "g", skipMemoryKeep: false, summary: "s", actions: [],
            intents: [VoiceMemoIntent(kind: .reminder, confidence: 0.95, title: "Send Jacob the results")])
        let t = MemoryHubMemoTitler.heuristicTitle(plan: plan, transcript: "x", now: now)
        try expect(t.title == "Send Jacob the results", "short title untouched by the char cap: \(t.title)")
    }

    await test("remediation_snapshotHeuristic_cjk_charCapped") {
        // The sweep path (heuristicTitle(snapshot:)) funnels through the same clean(); a CJK
        // snapshot field must also be bounded before it is written unattended at launch/wake.
        let longCJK = String(repeating: "あ", count: 200)
        let snap = PlanSnapshot(memoId: "m1", provenance: .heuristic, version: 1,
                                createdAt: "2026-06-25T10:00:00Z",
                                intents: [snapIntent("i1", "reminder", 0.95, title: longCJK)])
        let t = MemoryHubMemoTitler.heuristicTitle(snapshot: snap, now: now)
        try expect(t.title.count <= 121, "snapshot heuristic char-capped, got \(t.title.count)")
    }

    // MARK: Finding 3 — launchSweep persists once (writes survive, edited preserved)

    await test("remediation_sweep_singleWrite_titlesPersist") {
        // Behavioural guard that the single-save refactor still persists every written title
        // (the prune(cache) save after the loop must include the in-loop mutations).
        try await withTitleTempHome {
            for i in 0..<3 {
                let snap = PlanSnapshot(memoId: "sw-\(i)", provenance: .heuristic, version: 1,
                                        createdAt: "2026-06-25T10:00:00Z",
                                        intents: [snapIntent("i1", "reminder", 0.95, title: "Title \(i)")])
                _ = try MemoryHubPlanSnapshotStore.append(snap)
            }
            let n = MemoryHubMemoTitler.launchSweep(now: now)
            try expect(n == 3, "all three titled in one sweep (got \(n))")
            // Re-load from disk (not the in-loop cache) to prove the single save flushed them.
            let reloaded = MemoryHubMemoTitleStore.load()
            for i in 0..<3 {
                try expect(reloaded["sw-\(i)"]?.title == "Title \(i)",
                           "sw-\(i) persisted to disk: \(String(describing: reloaded["sw-\(i)"]))")
            }
        }
    }

    await test("remediation_sweep_singleWrite_preservesEdited") {
        // The in-memory edited-pin guard must still hold with the single-write path: a pinned
        // human edit is left untouched even though the loop mutates the shared cache dict.
        try await withTitleTempHome {
            let snap = PlanSnapshot(memoId: "edited", provenance: .heuristic, version: 1,
                                    createdAt: "2026-06-25T10:00:00Z",
                                    intents: [snapIntent("i1", "reminder", 0.95, title: "Auto would say this")])
            _ = try MemoryHubPlanSnapshotStore.append(snap)
            let snap2 = PlanSnapshot(memoId: "fresh", provenance: .heuristic, version: 1,
                                     createdAt: "2026-06-25T10:00:00Z",
                                     intents: [snapIntent("i1", "reminder", 0.95, title: "New title")])
            _ = try MemoryHubPlanSnapshotStore.append(snap2)
            MemoryHubMemoTitleStore.put(mtitle("Human kept this", .edited, "2026-06-25T09:00:00Z"), memoId: "edited")

            let n = MemoryHubMemoTitler.launchSweep(now: now)
            try expect(n == 1, "only the un-titled memo is written (got \(n))")
            try expect(MemoryHubMemoTitleStore.title(for: "edited")?.provenance == .edited,
                       "edit preserved through the single-write sweep")
            try expect(MemoryHubMemoTitleStore.title(for: "edited")?.title == "Human kept this",
                       "edited title body unchanged")
            try expect(MemoryHubMemoTitleStore.title(for: "fresh")?.title == "New title",
                       "the un-titled memo got its heuristic")
        }
    }
}
