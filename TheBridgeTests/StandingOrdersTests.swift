// StandingOrdersTests.swift — PKT-9 v3.5
// Covers: StandingOrdersStore CRUD + optimistic concurrency,
// RoutingIndex rendering determinism, StandingOrdersComposer assembly
// and per-client overlay matching.

import Foundation
import TheBridgeLib

func runStandingOrdersTests() async {
    print("\n[StandingOrders]")

    // MARK: - Store

    await test("Store: read returns empty snapshot when no file exists") {
        try await withTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            let snap = try StandingOrdersStore.shared.read()
            try expect(snap.markdown == "", "expected empty markdown, got \(snap.markdown.count) chars")
            try expect(snap.estimatedTokens == 0)
        }
    }

    await test("Store: write+read round-trips identical markdown") {
        try await withTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            let body = "# Standing Orders\n\nBe terse."
            let written = try StandingOrdersStore.shared.write(body)
            let read = try StandingOrdersStore.shared.read()
            try expect(read.markdown == body)
            try expect(read.hash == written.hash)
        }
    }

    await test("Store: hash changes when content changes") {
        try await withTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("v1")
            let h1 = try StandingOrdersStore.shared.read().hash
            _ = try StandingOrdersStore.shared.write("v2")
            let h2 = try StandingOrdersStore.shared.read().hash
            try expect(h1 != h2, "hash should differ across content")
        }
    }

    await test("Store: expectedHash matching the current snapshot allows write") {
        try await withTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("v1")
            let current = try StandingOrdersStore.shared.read().hash
            _ = try StandingOrdersStore.shared.write("v2", expectedHash: current)
            try expect(try StandingOrdersStore.shared.read().markdown == "v2")
        }
    }

    await test("Store: stale expectedHash throws and leaves file untouched") {
        try await withTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("v1")
            do {
                _ = try StandingOrdersStore.shared.write("v2", expectedHash: "0000000000000000")
                try expect(false, "expected staleHash to throw")
            } catch StandingOrdersStore.WriteError.staleHash {
                // expected
            }
            try expect(try StandingOrdersStore.shared.read().markdown == "v1",
                       "file must not change on stale-hash failure")
        }
    }

    await test("Store: seedIfEmpty installs template only when file absent") {
        try await withTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            try StandingOrdersStore.shared.seedIfEmpty(with: .soloDevTerse)
            let seeded = try StandingOrdersStore.shared.read().markdown
            try expect(seeded.contains("Skip filler"))

            // Modify, then seedIfEmpty must NOT overwrite.
            _ = try StandingOrdersStore.shared.write("custom user copy")
            try StandingOrdersStore.shared.seedIfEmpty(with: .cautious)
            try expect(try StandingOrdersStore.shared.read().markdown == "custom user copy")
        }
    }

    await test("Store: all 3 templates have non-empty bodies + distinct labels") {
        let templates = StandingOrdersStore.Template.allCases
        try expect(templates.count == 3)
        for t in templates {
            try expect(!t.body.isEmpty)
            try expect(!t.label.isEmpty)
        }
        let labels = Set(templates.map { $0.label })
        try expect(labels.count == 3, "labels must be distinct")
    }

    // MARK: - RoutingIndex

    await test("RoutingIndex: empty list renders placeholder") {
        let out = RoutingIndex.render([])
        try expect(out.contains("None registered"))
    }

    await test("RoutingIndex: skills are sorted alphabetically by slug") {
        let out = RoutingIndex.render([
            sampleSkill("zeta", name: "Zeta"),
            sampleSkill("alpha", name: "Alpha"),
            sampleSkill("mu", name: "Mu"),
        ])
        let alphaIdx = out.range(of: "(`alpha`")!.lowerBound
        let muIdx = out.range(of: "(`mu`")!.lowerBound
        let zetaIdx = out.range(of: "(`zeta`")!.lowerBound
        try expect(alphaIdx < muIdx && muIdx < zetaIdx, "skills must be sorted by slug")
    }

    await test("RoutingIndex: triggers + anti-triggers are surfaced") {
        let out = RoutingIndex.render([sampleSkill("foo", name: "Foo",
            triggers: ["new foo", "edit foo"],
            antiTriggers: ["delete foo"])])
        try expect(out.contains("triggers: new foo, edit foo"))
        try expect(out.contains("anti: delete foo"))
    }

    await test("RoutingIndex: description newlines collapse to one logical line") {
        let multiline = "line one\nline two\nline three"
        let out = RoutingIndex.render([sampleSkill("foo", name: "Foo",
            description: multiline)])
        try expect(out.contains("line one line two line three"))
        try expect(!out.contains("line one\n  line two"))
    }

    // MARK: - Composer

    await test("Composer: with no skills, output still contains standing orders + index header") {
        let composed = StandingOrdersComposer.compose(
            standingOrders: "# orders\n\nbe nice",
            skills: []
        )
        try expect(composed.text.contains("# orders"))
        try expect(composed.text.contains("be nice"))
        try expect(composed.text.contains("## Routing skills available"))
    }

    await test("Composer: skips standing-orders section when empty") {
        let composed = StandingOrdersComposer.compose(
            standingOrders: "   \n  \n",
            skills: [sampleSkill("foo", name: "Foo")]
        )
        try expect(!composed.text.contains("# orders"))
        try expect(composed.text.contains("(`foo`"))
    }

    await test("Composer: client overlay is inserted when client matches") {
        let composed = StandingOrdersComposer.compose(
            standingOrders: "base",
            skills: [],
            connectingClient: "claude-code-2.1.0",
            overlays: [
                StandingOrdersComposer.ClientOverlay(
                    clientName: "claude-code",
                    addendum: "Use code blocks for diffs."
                )
            ]
        )
        try expect(composed.text.contains("Client-specific notes (claude-code-2.1.0)"))
        try expect(composed.text.contains("Use code blocks for diffs."))
        try expect(composed.clientName == "claude-code-2.1.0")
    }

    await test("Composer: missing client overlay does NOT add a section") {
        let composed = StandingOrdersComposer.compose(
            standingOrders: "base",
            skills: [],
            connectingClient: "cursor",
            overlays: [
                StandingOrdersComposer.ClientOverlay(clientName: "claude-code", addendum: "x")
            ]
        )
        try expect(!composed.text.contains("Client-specific notes"))
    }

    await test("Composer: token estimate is positive for non-empty content") {
        let composed = StandingOrdersComposer.compose(
            standingOrders: "some orders worth a few tokens",
            skills: [sampleSkill("foo", name: "Foo")]
        )
        try expect(composed.estimatedTokens > 0)
    }

    // MARK: - PKT v3.6·8 — Universal Standing Orders amendment

    await test("Composer: trailer is suppressed when standing-orders already has ## Routing skills") {
        let body = """
        # orders

        body content

        ## Routing skills

        - **inline-keepr** — already curated inline
        """
        let composed = StandingOrdersComposer.compose(
            standingOrders: body,
            skills: [sampleSkill("foo", name: "Foo")]
        )
        // Trailer auto-render is suppressed; only the inline curated section remains.
        let matches = composed.text.components(separatedBy: "## Routing skills").count - 1
        try expect(matches == 1, "expected exactly one '## Routing skills' header, got \(matches)")
        // The skill from the array is NOT auto-rendered when inline section is present.
        try expect(!composed.text.contains("(`foo`"),
                   "auto-trailer should be suppressed when inline routing section present")
    }

    await test("Composer: trailer still appended when standing-orders has no inline routing section") {
        // Regression guard for the prior contract — empty/no-routing input still gets the trailer.
        let composed = StandingOrdersComposer.compose(
            standingOrders: "# orders\n\nno routing section here",
            skills: [sampleSkill("foo", name: "Foo")]
        )
        try expect(composed.text.contains("## Routing skills available"))
        try expect(composed.text.contains("(`foo`"))
    }

    await test("Composer: v6.5.0 principle anchors survive composition") {
        let body = """
        # Standing Orders

        ## 1. Role overlay — Keepr

        Adopt the **Keepr** role.

        ## 2. Capabilities & delegation

        When work exceeds your scope, **write a packet**.

        ## 5. Context priority & the Pillars

        **PLEASE — the receive side (generate, restore, fuel):**

        ## 7. The Bridge — operational context

        **Sensitive paths.** The Bridge enforces a Sensitive Paths list.

        **Notion implementation:** PACKETS DS row.

        SSOT: https://www.notion.so/28acbb58889e80d5b111ed23b996c304
        """
        let composed = StandingOrdersComposer.compose(
            standingOrders: body,
            skills: []
        )
        // These anchors must survive composition unchanged so any MCP client
        // receives the universal chief-of-staff frame at handshake.
        try expect(composed.text.contains("Role overlay — Keepr"))
        try expect(composed.text.contains("write a packet"))
        try expect(composed.text.contains("PLEASE — the receive side"))
        try expect(composed.text.contains("Notion implementation:"))
        try expect(composed.text.contains("Sensitive paths."))
        try expect(composed.text.contains("https://www.notion.so/28acbb58889e80d5b111ed23b996c304"))
    }

    // MARK: - Hash determinism

    await test("Hash: same input yields same hash; tiny diff changes it") {
        let a = StandingOrdersStore.shortHash("hello world")
        let b = StandingOrdersStore.shortHash("hello world")
        let c = StandingOrdersStore.shortHash("hello world!")
        try expect(a == b)
        try expect(a != c)
        try expect(a.count == 16, "expected 16-hex short hash, got \(a.count)")
    }
}

// MARK: - Test helpers (local, not exported)

private func sampleSkill(
    _ slug: String,
    name: String,
    domain: String? = "FOCUS",
    maturity: String? = "Stable",
    description: String = "A short description.",
    triggers: [String] = [],
    antiTriggers: [String] = []
) -> RoutingSkillSummary {
    RoutingSkillSummary(
        slug: slug,
        name: name,
        domain: domain,
        maturity: maturity,
        description: description,
        triggers: triggers,
        antiTriggers: antiTriggers
    )
}

/// Reuse the same tmp-home pattern as PathMigrationTests so Standing
/// Orders store lands under a per-test directory.
private func withTempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("StandingOrders-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
