// SkillVsCommandSplitTests.swift — cmd-ux (LOCK the skill-vs-command split)
// NotionBridge · Tests
//
// EXPLICIT OPERATOR REQUIREMENT — a regression LOCK, not coverage filler.
//
// Two code paths intentionally differ in WHAT they return, and that
// difference must NEVER blur. These named tests fail loudly the moment a
// future change makes them converge:
//
//   • `fetch_skill` (agent tool, SkillsModule): ONE tool call returns
//     BOTH the markdown `content` (from /markdown) AND the flattened
//     `properties` (from getPage) in one envelope — two internal
//     fetches, one payload. The agent gets the whole page.
//
//   • Hot-key command (CommandsManager.body → CommandPaletteCoordinator
//     .commit → CommandBridgeController clipboard): BODY-ONLY markdown via
//     /markdown. It must NEVER fetch or leak page `properties` — the
//     user pastes a clean body, not a metadata dump.
//
// ZERO network: the command path is driven through an INJECTED body
// fetcher; the fetch_skill path through the production envelope builder
// (`buildSkillResultForTesting`) with a synthetic properties blob.

import Foundation
import MCP
import NotionBridgeLib

func runSkillVsCommandSplitTests() async {
    print("\n\u{1F512} Skill-vs-Command Split LOCK Tests (cmd-ux regression lock)")

    @Sendable func mdJSON(_ markdown: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["markdown": markdown], options: [])
        return String(data: data, encoding: .utf8)!
    }

    // A dashed-UUID page id the normalizer accepts.
    let pageId = "aaaa1111-bbbb-2222-cccc-3333dddd4444"

    // ── LOCK 1: command commit path yields ONLY the markdown body ─────
    //
    //   Drive the EXACT production path the hot-key uses — coordinator
    //   commit → applyCommit → clipboard — with an injected body fetcher.
    //   The clipboard payload must be byte-for-byte the resolved
    //   markdown. If a future change ever folded page `properties` into
    //   the command path, the injected body (which carries NO property
    //   text) could not still equal the clipboard verbatim.
    await test("LOCK: CommandsManager/coordinator commit yields ONLY the markdown body (no properties)") {
        // The body deliberately contains NO property-shaped text. A
        // synthetic getPage-style properties dict is built but is NEVER
        // handed to the command path — proving the path has no such input.
        let body = "# Email Signature\n\nBest,\nIsaiah\n— sent via Notion Bridge"
        let syntheticPageProperties: [String: Any] = [
            "Status": ["select": ["name": "Published"]],
            "Owner": ["people": [["name": "Isaiah Peters"]]],
            "Secret": ["rich_text": [["plain_text": "DO-NOT-LEAK"]]]
        ]
        // syntheticPageProperties exists only to assert the command path
        // has nowhere to put it — CommandsManager.body takes a pageId and
        // a body fetcher, never a properties blob.
        _ = syntheticPageProperties

        nonisolated(unsafe) var fetchCalls: [String] = []
        let mgr = CommandsManager(fetcher: { id in
            fetchCalls.append(id)
            return mdJSON(body)   // /markdown body ONLY — never properties
        })
        let cb = InMemoryClipboard(initial: "user-prior-clip")
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider([
                CommandDescriptor(id: pageId, name: "Email Signature",
                                  abbreviation: "sig")
            ]),
            manager: mgr)
        let ctrl = await CommandBridgeController(
            clipboard: cb, coordinator: coord)

        let result = await coord.commit(
            CommandDescriptor(id: pageId, name: "Email Signature", abbreviation: "sig"))
        guard case .paste(let pasted) = result else {
            throw TestError.assertion("expected .paste, got \(result)")
        }
        await ctrl.applyCommit(result)

        // (1) The committed payload is EXACTLY the resolved markdown body.
        try expect(pasted == body,
                   "commit payload must be the verbatim body, got \(pasted)")
        // (2) The clipboard holds ONLY that body — nothing else merged in.
        try expect(cb.readString() == body,
                   "clipboard must hold ONLY the markdown body, got \(cb.readString() ?? "nil")")
        try expect(cb.writeCount == 1, "exactly one clipboard write, got \(cb.writeCount)")
        // (3) Exactly ONE fetch — the /markdown body fetch. There is no
        //     second getPage/properties fetch in the command path.
        try expect(fetchCalls.count == 1,
                   "the command path must do exactly ONE (body) fetch, got \(fetchCalls.count)")
        // (4) Hard anti-leak: no property name/value can appear on the
        //     clipboard (the body never contained them, and the path has
        //     no properties input — this pins the consequence).
        let clip = cb.readString() ?? ""
        for needle in ["Status", "Published", "Owner", "DO-NOT-LEAK", "select", "rich_text"] {
            try expect(!clip.contains(needle),
                       "page-property text \"\(needle)\" must NEVER reach the command clipboard")
        }
    }

    await test("LOCK: CommandsManager.body returns the verbatim resolved body for ANY properties-like page") {
        // Even if the page "had" rich properties upstream, the command
        // data layer only ever sees the /markdown body via its fetcher.
        let body = "plain command body — no metadata here"
        let mgr = CommandsManager(fetcher: { _ in mdJSON(body) })
        let out = try await mgr.body(forPageId: pageId)
        try expect(out == body,
                   "CommandsManager.body must be body-only, got \(out)")
    }

    // ── LOCK 2: fetch_skill envelope still carries BOTH ───────────────
    //
    //   The agent tool MUST keep returning content AND properties in one
    //   payload. This drives the EXACT production envelope builder.
    await test("LOCK: fetch_skill envelope carries BOTH content AND properties (one payload, two fetches)") {
        let skillBody = "## How to greet\n\n- Be warm\n- Be brief"
        let pageProps: [String: Any] = [
            "Status": ["type": "select", "select": ["name": "Active"]],
            "Priority": ["type": "number", "number": 3]
        ]
        let env = await SkillsModule.buildSkillResultForTesting(
            name: "greeter", title: "Greeter Skill",
            url: "https://www.notion.so/greeter",
            markdownJSONOrText: mdJSON(skillBody),
            summary: "", triggerPhrases: [], antiTriggerPhrases: [],
            pageProperties: pageProps
        ) { _ in nil }

        guard case .object(let o) = env else {
            throw TestError.assertion("envelope must be an object")
        }
        // content — the markdown body (from the /markdown fetch).
        guard case .string(let content)? = o["content"] else {
            throw TestError.assertion("fetch_skill envelope MUST carry a `content` string")
        }
        try expect(content.contains("How to greet") && content.contains("Be warm"),
                   "content must be the markdown body, got \(content)")
        // properties — the flattened getPage properties (the OTHER fetch).
        guard case .object(let props)? = o["properties"] else {
            throw TestError.assertion("fetch_skill envelope MUST carry a `properties` object")
        }
        try expect(!props.isEmpty,
                   "a DB-backed skill page must flatten non-empty properties")
        try expect(props["Status"] != nil && props["Priority"] != nil,
                   "the flattened properties must include the page's property keys, got \(props.keys.sorted())")
        // BOTH present in the SAME payload — the defining contrast vs the
        // body-only command path locked above.
        try expect(o["content"] != nil && o["properties"] != nil,
                   "the agent fetch_skill payload must carry content AND properties together")
    }

    await test("LOCK: the two paths are asymmetric — command body has no properties; fetch_skill has both") {
        // One assertion that pins the asymmetry itself so a future change
        // collapsing them fails HERE with a clear message.
        let body = "command-only body"
        let mgr = CommandsManager(fetcher: { _ in mdJSON(body) })
        let commandOut = try await mgr.body(forPageId: pageId)

        let env = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "S", url: "u",
            markdownJSONOrText: mdJSON(body),
            summary: "", triggerPhrases: [], antiTriggerPhrases: [],
            pageProperties: ["K": ["type": "checkbox", "checkbox": true]]
        ) { _ in nil }
        guard case .object(let o) = env,
              case .object(let props)? = o["properties"],
              o["content"] != nil else {
            throw TestError.assertion("fetch_skill must still expose content + properties")
        }
        try expect(commandOut == body,
                   "command path is body-only (a String, no envelope, no properties)")
        try expect(!props.isEmpty && props["K"] != nil,
                   "fetch_skill path additionally carries flattened properties — the split holds")
    }
}
