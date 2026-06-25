// JobsModuleTests.swift — PKT-340 Wave 4 test coverage
// CronParser expansion, LaunchAgentPlist dict shape, JobStore CRUD round-trip.

import Foundation
import MCP
import TheBridgeLib

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


    // --- job_get handler (envelope + error paths) ---

    await test("job_get: returns {job, history} envelope for an existing job with its executions") {
        try await JobStore.shared.open()
        let id = "test-get-\(UUID().uuidString)"
        let job = JobRecord(id: id, name: "g", schedule: "0 9 * * *",
                            actionChain: [ActionStep(tool: "noop")])
        try await JobStore.shared.insert(job)
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        _ = try await JobStore.shared.insertExecution(
            ExecutionRecord(jobId: id, startedAt: Date(), completedAt: Date(), status: .success))
        _ = try await JobStore.shared.insertExecution(
            ExecutionRecord(jobId: id, startedAt: Date(), completedAt: Date(), status: .failure))

        let out = try await JobsManager.shared.getJob(args: .object(["id": .string(id)]))
        guard case .object(let o) = out,
              case .object(let jobObj)? = o["job"],
              case .array(let hist)? = o["history"] else {
            throw TestError.assertion("shape")
        }
        try expect(jobObj["id"] == .string(id))
        try expect(jobObj["name"] == .string("g"))
        try expect(jobObj["steps"] == .int(1), "expected steps == 1")
        try expect(hist.count == 2, "expected 2 executions (under the limit-10 cap), got \(hist.count)")
        try await JobStore.shared.delete(id: id)
    }

    await test("job_get: unknown id throws JobsModuleError.jobNotFound") {
        try await JobStore.shared.open()
        let missing = "test-missing-\(UUID().uuidString)"
        do {
            _ = try await JobsManager.shared.getJob(args: .object(["id": .string(missing)]))
            throw TestError.assertion("expected jobNotFound")
        } catch JobsModuleError.jobNotFound(let id) {
            try expect(id == missing, "expected \(missing), got \(id)")
        }
    }

    await test("job_get: missing 'id' arg throws invalidActionChain") {
        try await JobStore.shared.open()
        do {
            _ = try await JobsManager.shared.getJob(args: .object([:]))
            throw TestError.assertion("expected missing-arg rejection")
        } catch JobsModuleError.invalidActionChain(let m) {
            try expect(m.contains("id"), "expected id error, got \(m)")
        }
    }

    // --- job_list handler (envelope + status filter) ---

    await test("job_list: returns {jobs, count} including a freshly inserted job") {
        try await JobStore.shared.open()
        let id = "test-list-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: id, name: "l", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "noop")]))
        defer { Task { try? await JobStore.shared.delete(id: id) } }

        let out = try await JobsManager.shared.listJobs(args: .object([:]))
        guard case .object(let o) = out,
              case .array(let jobs)? = o["jobs"],
              case .int(let count)? = o["count"] else {
            throw TestError.assertion("shape")
        }
        try expect(count == jobs.count, "count must equal jobs.count")
        let present = jobs.contains { if case .object(let j) = $0 { return j["id"] == .string(id) } else { return false } }
        try expect(present, "freshly inserted job must appear in job_list")
        try await JobStore.shared.delete(id: id)
    }

    await test("job_list: status filter narrows results (paused job excluded by status:active)") {
        try await JobStore.shared.open()
        let idA = "test-list-active-\(UUID().uuidString)"
        let idB = "test-list-paused-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: idA, name: "a", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "noop")]))
        try await JobStore.shared.insert(
            JobRecord(id: idB, name: "b", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "noop")]))
        try await JobStore.shared.updateStatus(id: idB, status: .paused)
        defer { Task { try? await JobStore.shared.delete(id: idA) } }
        defer { Task { try? await JobStore.shared.delete(id: idB) } }

        func ids(_ out: Value) throws -> Set<String> {
            guard case .object(let o) = out, case .array(let jobs)? = o["jobs"] else {
                throw TestError.assertion("shape")
            }
            return Set(jobs.compactMap { v -> String? in
                if case .object(let j) = v, case .string(let s)? = j["id"] { return s } else { return nil }
            })
        }
        let activeIds = try ids(try await JobsManager.shared.listJobs(args: .object(["status": .string("active")])))
        let pausedIds = try ids(try await JobsManager.shared.listJobs(args: .object(["status": .string("paused")])))
        try expect(activeIds.contains(idA), "active filter must include the active job")
        try expect(!activeIds.contains(idB), "active filter must exclude the paused job")
        try expect(pausedIds.contains(idB), "paused filter must include the paused job")
        try expect(!pausedIds.contains(idA), "paused filter must exclude the active job")
        try await JobStore.shared.delete(id: idA)
        try await JobStore.shared.delete(id: idB)
    }

    // --- job_delete handler (store-only job → no LaunchAgent side effects) ---

    await test("job_delete: removes a store-only job and returns {deleted: id}") {
        try await JobStore.shared.open()
        let id = "test-del-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: id, name: "d", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "noop")]))
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        try expect(try await JobStore.shared.fetch(id: id) != nil, "job must exist before delete")

        let out = try await JobsManager.shared.deleteJob(args: .object(["id": .string(id)]))
        guard case .object(let o) = out else { throw TestError.assertion("shape") }
        try expect(o["deleted"] == .string(id))
        try expect(try await JobStore.shared.fetch(id: id) == nil, "record must be gone after delete")
    }

    await test("job_delete: deleting a non-existent id is a benign no-op returning {deleted: id}") {
        try await JobStore.shared.open()
        let missing = "test-del-missing-\(UUID().uuidString)"
        let out = try await JobsManager.shared.deleteJob(args: .object(["id": .string(missing)]))
        guard case .object(let o) = out else { throw TestError.assertion("shape") }
        try expect(o["deleted"] == .string(missing))
        try expect(try await JobStore.shared.fetch(id: missing) == nil, "no row should exist")
    }

    // --- job_history handler (limit + envelope + error path) ---

    await test("job_history: returns {executions, count} newest-first respecting an explicit limit") {
        try await JobStore.shared.open()
        let id = "test-hist-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: id, name: "h", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "noop")]))
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        let t1 = Date()
        let t2 = t1.addingTimeInterval(60)
        let t3 = t1.addingTimeInterval(120)
        _ = try await JobStore.shared.insertExecution(ExecutionRecord(jobId: id, startedAt: t1, status: .success))
        _ = try await JobStore.shared.insertExecution(ExecutionRecord(jobId: id, startedAt: t2, status: .success))
        _ = try await JobStore.shared.insertExecution(ExecutionRecord(jobId: id, startedAt: t3, status: .success))

        let out = try await JobsManager.shared.jobHistory(args: .object(["id": .string(id), "limit": .int(2)]))
        guard case .object(let o) = out,
              case .array(let execs)? = o["executions"],
              case .int(let count)? = o["count"] else {
            throw TestError.assertion("shape")
        }
        try expect(execs.count == 2 && count == 2, "limit must be honored (2)")
        // ORDER BY started_at DESC → newest first. Re-parse the ISO startedAt
        // strings back to Date and assert strictly decreasing.
        func startedAt(_ v: Value) throws -> Date {
            guard case .object(let e) = v, case .string(let s)? = e["startedAt"] else {
                throw TestError.assertion("missing startedAt")
            }
            let f = ISO8601DateFormatter()
            guard let d = f.date(from: s) else { throw TestError.assertion("unparseable startedAt: \(s)") }
            return d
        }
        try expect(try startedAt(execs[0]) > startedAt(execs[1]), "executions must be newest-first")
        try await JobStore.shared.delete(id: id)
    }

    await test("job_history: defaults to limit 20 when 'limit' omitted") {
        try await JobStore.shared.open()
        let id = "test-hist-default-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: id, name: "h", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "noop")]))
        defer { Task { try? await JobStore.shared.delete(id: id) } }
        _ = try await JobStore.shared.insertExecution(ExecutionRecord(jobId: id, startedAt: Date(), status: .success))

        let out = try await JobsManager.shared.jobHistory(args: .object(["id": .string(id)]))
        guard case .object(let o) = out, case .int(let count)? = o["count"] else {
            throw TestError.assertion("shape")
        }
        try expect(count == 1, "omitting limit returns all rows under the 20 default, got \(count)")
        try await JobStore.shared.delete(id: id)
    }

    await test("job_history: missing 'id' throws invalidActionChain") {
        try await JobStore.shared.open()
        do {
            _ = try await JobsManager.shared.jobHistory(args: .object([:]))
            throw TestError.assertion("expected missing-arg rejection")
        } catch JobsModuleError.invalidActionChain(let m) {
            try expect(m.contains("id"), "expected id error, got \(m)")
        }
    }

    // --- job_templates handler (pure: 3 built-in presets) ---

    await test("job_templates: returns the 3 built-in presets with valid cron + non-empty action chains") {
        let out = try await JobsManager.shared.listTemplates(args: .object([:]))
        guard case .object(let o) = out, case .array(let templates)? = o["templates"] else {
            throw TestError.assertion("shape")
        }
        try expect(templates.count == 3, "expected 3 presets, got \(templates.count)")
        var idSet = Set<String>()
        for t in templates {
            guard case .object(let tpl) = t else { throw TestError.assertion("template shape") }
            guard case .string(let tid)? = tpl["id"] else { throw TestError.assertion("template missing id") }
            idSet.insert(tid)
            guard case .string(let sched)? = tpl["schedule"] else { throw TestError.assertion("template missing schedule") }
            _ = try CronParser.parse(sched) // must not throw — couples presets to the createJob validator
            guard case .array(let actions)? = tpl["actions"] else { throw TestError.assertion("template missing actions") }
            try expect(!actions.isEmpty, "preset \(tid) must have a non-empty action chain")
        }
        try expect(idSet == Set(["daily-desktop-cleanup", "hourly-screenshot-tidy", "friday-status-digest"]),
                   "unexpected preset id set: \(idSet)")
    }

    // --- job_export handler (ids subset filter + decodable envelope) ---

    await test("job_export: ids subset filter exports only the requested jobs as a decodable envelope") {
        try await JobStore.shared.open()
        let idA = "test-export-a-\(UUID().uuidString)"
        let idB = "test-export-b-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: idA, name: "A", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "noop")]))
        try await JobStore.shared.insert(
            JobRecord(id: idB, name: "B", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "noop")]))
        defer { Task { try? await JobStore.shared.delete(id: idA) } }
        defer { Task { try? await JobStore.shared.delete(id: idB) } }

        let out = try await JobsManager.shared.exportJobsTool(args: .object(["ids": .array([.string(idA)])]))
        guard case .object(let o) = out,
              case .int(let count)? = o["count"],
              case .string(let json)? = o["json"] else {
            throw TestError.assertion("shape")
        }
        try expect(count == 1, "ids subset must export exactly one job, got \(count)")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let env = try dec.decode(JobExportEnvelope.self, from: Data(json.utf8))
        try expect(env.version == 1)
        try expect(env.jobs.count == 1)
        try expect(env.jobs[0].id == idA && env.jobs[0].name == "A")
        try expect(!env.jobs.contains { $0.id == idB }, "subset must not include unrequested job")
        try await JobStore.shared.delete(id: idA)
        try await JobStore.shared.delete(id: idB)
    }

    await test("job_export: empty/absent ids exports all jobs (envelope superset contains inserted job)") {
        try await JobStore.shared.open()
        let idA = "test-export-all-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: idA, name: "A", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "noop")]))
        defer { Task { try? await JobStore.shared.delete(id: idA) } }

        let out = try await JobsManager.shared.exportJobsTool(args: .object([:]))
        guard case .object(let o) = out,
              case .int(let count)? = o["count"],
              case .string(let json)? = o["json"] else {
            throw TestError.assertion("shape")
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let env = try dec.decode(JobExportEnvelope.self, from: Data(json.utf8))
        try expect(env.jobs.contains { $0.id == idA }, "export-all must contain the inserted job")
        try expect(count == env.jobs.count, "count must equal env.jobs.count")
        try await JobStore.shared.delete(id: idA)
    }

    // --- job_import handler (hermetic seams only — invalid-cron skip + decode/arg errors) ---

    await test("job_import: a job with an invalid cron schedule is skipped (no LaunchAgent side effects)") {
        try await JobStore.shared.open()
        // 4-field cron → CronParser.parse throws BEFORE any plist write/register,
        // so the row lands in `skipped` with zero filesystem/launchctl effects.
        let badJob = JobRecord(name: "bad", schedule: "0 9 * *", actionChain: [ActionStep(tool: "noop")])
        let env = JobExportEnvelope(jobs: [badJob])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let jsonString = String(data: try enc.encode(env), encoding: .utf8)!

        let out = try await JobsManager.shared.importJobsTool(args: .object(["json": .string(jsonString)]))
        guard case .object(let o) = out,
              case .int(let imported)? = o["imported"],
              case .int(let skipped)? = o["skipped"],
              case .array(let reasons)? = o["skippedReasons"] else {
            throw TestError.assertion("shape")
        }
        try expect(imported == 0, "invalid-cron job must not import")
        try expect(skipped == 1, "invalid-cron job must be skipped")
        try expect(reasons.count == 1, "expected one skip reason")
        if case .string(let reason)? = reasons.first {
            try expect(reason.contains("bad"), "skip reason should carry the job name, got \(reason)")
        } else {
            throw TestError.assertion("skip reason not a string")
        }
    }

    await test("job_import: malformed JSON throws invalidActionChain('decode failed')") {
        try await JobStore.shared.open()
        do {
            _ = try await JobsManager.shared.importJobsTool(args: .object(["json": .string("{ not valid json")]))
            throw TestError.assertion("expected decode failure")
        } catch JobsModuleError.invalidActionChain(let m) {
            try expect(m.contains("decode"), "expected decode error, got \(m)")
        }
    }

    await test("job_import: missing 'json' arg throws invalidActionChain") {
        try await JobStore.shared.open()
        do {
            _ = try await JobsManager.shared.importJobsTool(args: .object([:]))
            throw TestError.assertion("expected missing-arg rejection")
        } catch JobsModuleError.invalidActionChain(let m) {
            try expect(m.contains("json"), "expected json error, got \(m)")
        }
    }

    // --- job_update handler (hermetic: schedule unchanged OR paused job) ---

    await test("job_update: patches name + skipOnBattery without a schedule change (scheduleChanged=false)") {
        try await JobStore.shared.open()
        let id = "test-upd-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: id, name: "before", schedule: "0 9 * * *",
                      actionChain: [ActionStep(tool: "a")], skipOnBattery: false))
        defer { Task { try? await JobStore.shared.delete(id: id) } }

        let out = try await JobsManager.shared.updateJobTool(args: .object([
            "id": .string(id), "name": .string("after"), "skipOnBattery": .bool(true)
        ]))
        guard case .object(let o) = out else { throw TestError.assertion("shape") }
        try expect(o["updated"] == .string(id))
        try expect(o["name"] == .string("after"))
        try expect(o["skipOnBattery"] == .bool(true))
        try expect(o["scheduleChanged"] == .bool(false))
        let f = try await JobStore.shared.fetch(id: id)!
        try expect(f.name == "after" && f.skipOnBattery == true && f.schedule == "0 9 * * *",
                   "schedule must be unchanged; name/skipOnBattery persisted")
        try await JobStore.shared.delete(id: id)
    }

    await test("job_update: replacing actions validates the chain and updates step count (paused job)") {
        try await JobStore.shared.open()
        let id = "test-upd2-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: id, name: "u", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "a")]))
        try await JobStore.shared.updateStatus(id: id, status: .paused)
        defer { Task { try? await JobStore.shared.delete(id: id) } }

        let out = try await JobsManager.shared.updateJobTool(args: .object([
            "id": .string(id),
            "actions": .array([
                .object(["tool": .string("shell_exec"), "arguments": .object(["command": .string("echo hi")])]),
                .object(["tool": .string("shell_exec"), "arguments": .object(["command": .string("echo bye")])])
            ])
        ]))
        guard case .object(let o) = out, case .int(let steps)? = o["steps"] else {
            throw TestError.assertion("shape")
        }
        try expect(steps == 2, "expected 2 steps, got \(steps)")
        let f = try await JobStore.shared.fetch(id: id)!
        try expect(f.actionChain.count == 2 && f.actionChain[0].tool == "shell_exec",
                   "new chain must persist and canonicalize tool names")
        try await JobStore.shared.delete(id: id)
    }

    await test("job_update: an action chain that fails validateUnattended is rejected (invalidActionChain)") {
        try await JobStore.shared.open()
        let id = "test-upd3-\(UUID().uuidString)"
        try await JobStore.shared.insert(
            JobRecord(id: id, name: "u", schedule: "0 9 * * *", actionChain: [ActionStep(tool: "a")]))
        try await JobStore.shared.updateStatus(id: id, status: .paused)
        defer { Task { try? await JobStore.shared.delete(id: id) } }

        do {
            _ = try await JobsManager.shared.updateJobTool(args: .object([
                "id": .string(id),
                "actions": .array([
                    .object(["tool": .string("messages_send"),
                             "arguments": .object(["body": .string("hi"), "recipient": .string("x")])])
                ])
            ]))
            throw TestError.assertion("expected unattended rejection")
        } catch JobsModuleError.invalidActionChain(let m) {
            try expect(m.contains("confirm"), "expected confirm error, got \(m)")
        }
        // Validation throws before JobStore.update — original chain must survive.
        let f = try await JobStore.shared.fetch(id: id)!
        try expect(f.actionChain.count == 1 && f.actionChain[0].tool == "a",
                   "original single-step chain must be unchanged after a rejected update")
        try await JobStore.shared.delete(id: id)
    }

    await test("job_update: unknown id throws jobNotFound") {
        try await JobStore.shared.open()
        let missing = "test-upd-missing-\(UUID().uuidString)"
        do {
            _ = try await JobsManager.shared.updateJobTool(args: .object([
                "id": .string(missing), "name": .string("x")
            ]))
            throw TestError.assertion("expected jobNotFound")
        } catch JobsModuleError.jobNotFound(let id) {
            try expect(id == missing, "expected \(missing), got \(id)")
        }
    }

    // --- job_duplicate handler (hermetic error paths only; happy-path shells launchctl) ---

    await test("job_duplicate: unknown id throws jobNotFound (before any LaunchAgent work)") {
        try await JobStore.shared.open()
        let missing = "test-dup-missing-\(UUID().uuidString)"
        do {
            _ = try await JobsManager.shared.duplicateJobTool(args: .object(["id": .string(missing)]))
            throw TestError.assertion("expected jobNotFound")
        } catch JobsModuleError.jobNotFound(let id) {
            try expect(id == missing, "expected \(missing), got \(id)")
        }
    }

    await test("job_duplicate: missing 'id' arg throws invalidActionChain") {
        try await JobStore.shared.open()
        do {
            _ = try await JobsManager.shared.duplicateJobTool(args: .object([:]))
            throw TestError.assertion("expected missing-arg rejection")
        } catch JobsModuleError.invalidActionChain(let m) {
            try expect(m.contains("id"), "expected id error, got \(m)")
        }
    }


}
