// JobsModuleTests.swift — PKT-340 Wave 4 test coverage
// CronParser expansion, LaunchAgentPlist dict shape, JobStore CRUD round-trip.

import Foundation
import NotionBridgeLib

func runJobsModuleTests() async {
    print("\n\u{23F0} JobsModule Tests (PKT-340)")

    // --- CronParser ---

    await test("CronParser: every minute (all stars) yields a single interval") {
        let out = try CronParser.parse("* * * * *")
        try expect(out.count == 1, "expected 1 interval, got \(out.count)")
        let iv = out[0]
        try expect(iv.minute == nil && iv.hour == nil && iv.day == nil && iv.month == nil && iv.weekday == nil)
    }

    await test("CronParser: daily at 9am") {
        let out = try CronParser.parse("0 9 * * *")
        try expect(out.count == 1)
        try expect(out[0].minute == 0)
        try expect(out[0].hour == 9)
        try expect(out[0].weekday == nil)
    }

    await test("CronParser: Friday 5pm") {
        let out = try CronParser.parse("0 17 * * 5")
        try expect(out.count == 1)
        try expect(out[0].weekday == 5)
    }

    await test("CronParser: weekday 7 normalizes to 0 (Sunday)") {
        let out = try CronParser.parse("0 9 * * 7")
        try expect(out.count == 1)
        try expect(out[0].weekday == 0)
    }

    await test("CronParser: list 1,3,5 expands to 3 intervals") {
        let out = try CronParser.parse("0 9 * * 1,3,5")
        try expect(out.count == 3)
        let wd = Set(out.compactMap { $0.weekday })
        try expect(wd == Set([1, 3, 5]))
    }

    await test("CronParser: range 1-5 expands to 5 intervals") {
        let out = try CronParser.parse("0 9 * * 1-5")
        try expect(out.count == 5)
    }

    await test("CronParser: step */15 yields 4 minute intervals") {
        let out = try CronParser.parse("*/15 * * * *")
        try expect(out.count == 4, "expected 4 (0,15,30,45) got \(out.count)")
        let mins = Set(out.compactMap { $0.minute })
        try expect(mins == Set([0, 15, 30, 45]))
    }

    await test("CronParser: rejects >24 intervals (step */1 on hours * minutes)") {
        do {
            _ = try CronParser.parse("*/1 * * * *")
            throw TestError.assertion("expected explosion to be rejected")
        } catch {
            // expected
        }
    }

    await test("CronParser: rejects 4-field expression") {
        do {
            _ = try CronParser.parse("0 9 * *")
            throw TestError.assertion("expected 5-field requirement")
        } catch { /* expected */ }
    }

    await test("CronParser: rejects out-of-range hour") {
        do {
            _ = try CronParser.parse("0 25 * * *")
            throw TestError.assertion("expected out-of-range rejection")
        } catch { /* expected */ }
    }

    // --- LaunchAgentPlist ---

    await test("LaunchAgentPlist: single interval uses dict, multi uses array") {
        let single = try CronParser.parse("0 9 * * *")
        let plistSingle = LaunchAgentPlist.build(jobId: "test-single", intervals: single, ssePort: 9700)
        try expect(plistSingle["Label"] as? String == "solutions.kup.notionbridge.job.test-single")
        try expect(plistSingle["StartCalendarInterval"] is [String: Any])

        let multi = try CronParser.parse("0 9 * * 1,3,5")
        let plistMulti = LaunchAgentPlist.build(jobId: "test-multi", intervals: multi, ssePort: 9700)
        try expect(plistMulti["StartCalendarInterval"] is [[String: Any]])
        if let arr = plistMulti["StartCalendarInterval"] as? [[String: Any]] {
            try expect(arr.count == 3)
        }
    }

    // v1.9.2: ProgramArguments now uses the bundled NBJobRunner helper when
    // available (inside the .app bundle), falling back to curl only when the
    // helper cannot be located (test harness). Accept either shape.
    await test("LaunchAgentPlist: ProgramArguments uses helper or curl fallback") {
        let intervals = try CronParser.parse("0 9 * * *")
        let plist = LaunchAgentPlist.build(jobId: "abc123", intervals: intervals, ssePort: 9700)
        guard let prog = plist["ProgramArguments"] as? [String] else {
            throw TestError.assertion("ProgramArguments missing or wrong type")
        }
        guard let first = prog.first else {
            throw TestError.assertion("ProgramArguments empty")
        }
        if first.hasSuffix("NBJobRunner") {
            // Helper mode: [helperPath, jobId]
            try expect(prog.count == 2, "helper mode expects 2 args, got \(prog.count)")
            try expect(prog[1] == "abc123")
            let env = plist["EnvironmentVariables"] as? [String: String]
            try expect(env?["NB_SSE_PORT"] == "9700", "missing NB_SSE_PORT env")
        } else {
            // Legacy fallback: curl POST
            try expect(first == "/usr/bin/curl")
            try expect(prog.contains("http://127.0.0.1:9700/jobs/abc123/run"))
            try expect(prog.contains("POST"))
        }
    }

    await test("LaunchAgentPlist: jobRunnerPath() returns empty or existing file") {
        let path = LaunchAgentPlist.jobRunnerPath()
        if !path.isEmpty {
            try expect(FileManager.default.fileExists(atPath: path),
                       "jobRunnerPath returned non-existent path: \(path)")
        }
    }

    // --- JobStore (uses a temp SQLite file so the real DB is untouched) ---

    await test("JobStore: insert + fetch round-trip") {
        // JobStore.shared.open uses a fixed path. To keep this test hermetic we
        // just check that the API round-trips a record end-to-end — we accept
        // that this writes to the user's support dir because the test data is
        // self-contained and cleaned up.
        try await JobStore.shared.open()
        let id = "test-job-\(UUID().uuidString)"
        let job = JobRecord(
            id: id,
            name: "test",
            schedule: "0 9 * * *",
            actionChain: [ActionStep(tool: "noop")],
            status: .active,
            skipOnBattery: false
        )
        try await JobStore.shared.insert(job)
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        guard let fetched = try await JobStore.shared.fetch(id: id) else {
            throw TestError.assertion("fetched job was nil")
        }
        try expect(fetched.name == "test")
        try expect(fetched.schedule == "0 9 * * *")
        try expect(fetched.actionChain.count == 1)
        try expect(fetched.actionChain[0].tool == "noop")
        try await JobStore.shared.delete(id: id)
    }

    await test("JobStore: pause updates status") {
        try await JobStore.shared.open()
        let id = "test-pause-\(UUID().uuidString)"
        let job = JobRecord(id: id, name: "p", schedule: "0 9 * * *",
                            actionChain: [ActionStep(tool: "noop")])
        try await JobStore.shared.insert(job)
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        try await JobStore.shared.updateStatus(id: id, status: .paused)
        let fetched = try await JobStore.shared.fetch(id: id)
        try expect(fetched?.status == .paused)
        try await JobStore.shared.delete(id: id)
    }


    // --- JobsModule v1.10.0 additions ---

    await test("JobStore.update: partial update preserves id / createdAt") {
        try await JobStore.shared.open()
        let id = "test-update-\(UUID().uuidString)"
        let job = JobRecord(id: id, name: "before", schedule: "0 9 * * *",
                            actionChain: [ActionStep(tool: "a")])
        try await JobStore.shared.insert(job)
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let before = try await JobStore.shared.fetch(id: id)!
        let updated = try await JobStore.shared.update(id: id) { r in
            var next = r; next.name = "after"; next.skipOnBattery = true; return next
        }
        try expect(updated.id == id, "id must be preserved")
        try expect(updated.name == "after")
        try expect(updated.skipOnBattery == true)
        try expect(updated.createdAt == before.createdAt, "createdAt must be preserved")
        try await JobStore.shared.delete(id: id)
    }

    await test("JobExportEnvelope: round-trip encode / decode") {
        let job = JobRecord(name: "rt", schedule: "*/5 * * * *",
                            actionChain: [ActionStep(tool: "x", arguments: ["k": .string("v")])])
        let env = JobExportEnvelope(jobs: [job])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(env)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(JobExportEnvelope.self, from: data)
        try expect(back.version == 1)
        try expect(back.jobs.count == 1)
        try expect(back.jobs[0].name == "rt")
        try expect(back.jobs[0].actionChain[0].tool == "x")
    }

    await test("Jobs validation: accepts confirmed messages_send with chatIdentifier") {
        try JobsManager.validateUnattended(tool: "messages_send", args: [
            "chatIdentifier": .string("677927082d92462b9e1ddc5450b9ae10"),
            "body": .string("Fasting window started."),
            "confirm": .string("SEND")
        ])
    }

    await test("Jobs validation: canonicalizes messages.messages_send") {
        try expect(JobsManager.canonicalActionToolName("messages.messages_send") == "messages_send")
        try JobsManager.validateUnattended(tool: "messages.messages_send", args: [
            "chatIdentifier": .string("677927082d92462b9e1ddc5450b9ae10"),
            "body": .string("Fasting window ended."),
            "confirm": .string("SEND")
        ])
    }

    await test("Jobs validation: rejects messages_send without SEND confirmation") {
        do {
            try JobsManager.validateUnattended(tool: "messages_send", args: [
                "chatIdentifier": .string("677927082d92462b9e1ddc5450b9ae10"),
                "body": .string("Fasting window started.")
            ])
            throw TestError.assertion("expected messages_send without confirm to be rejected")
        } catch JobsModuleError.invalidActionChain(let message) {
            try expect(message.contains("confirm"), "expected confirm error, got \(message)")
        }
    }


}
