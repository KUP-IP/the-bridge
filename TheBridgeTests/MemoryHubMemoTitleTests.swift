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
        try expect(MemoryHubMemoTitler.isDefaultName("New Recording 3"), "Apple placeholder ⇒ default")
        try expect(MemoryHubMemoTitler.isDefaultName("   "), "blank ⇒ default")
    }
    await test("name_realName_isNotDefault") {
        try expect(!MemoryHubMemoTitler.isDefaultName("Bridge RT1"), "user name ⇒ honored")
        try expect(!MemoryHubMemoTitler.isDefaultName("Jacob sync notes"), "user name ⇒ honored")
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
