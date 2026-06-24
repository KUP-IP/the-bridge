# Skill Revision — Application Guide (operator paste)

Three Packet-Runner-compatible skill revisions are ready. They are **full rewrites**
(executor ≈59% changed), so they cannot be safely auto-applied via the surgical-only
Notion body tool — you apply them by hand for full fidelity. **Not needed live until
the pilot runs** (gated on provider selection + capability tests), so there's no rush.

| Skill | Revised file | Target Notion page | Size | Δ |
|---|---|---|---|---|
| executor | `executor-v8.1.0-packet-runner.md` | [b2eb533e…](https://app.notion.com/p/b2eb533e3be1465b86d41af6937db638) | 987 ln | 8.0.0 → **8.1.0-packet-runner** |
| orchestrator | `orchestrator-v7.1.0.md` | [d0925acd…](https://app.notion.com/p/d0925acdd04c4a15b60fc1c98245ff82) | 538 ln | 7.0.0 → **7.1.0** |
| close-agent | `close-agent-v3.2.0.md` | [6673dba8…](https://app.notion.com/p/6673dba826b14b1daa0a6aad084a861c) | 634 ln | 3.1.0 → **3.2.0** |

## ⚠️ Three caveats before you paste (the dialect doesn't round-trip raw)

1. **`<mention-page url="…"/>` tags** — these are inline page mentions in the source.
   Pasted raw they show as literal text. Either (a) leave them and re-mention by hand
   (executor has 25, orchestrator 9, close-agent 17 — mostly in §Composition / cross-refs,
   not the core contract), or (b) ask me to emit a paste-optimized version that turns each
   into a plain `https://app.notion.com/p/…` URL you can one-click convert to a mention.
2. **`<synced_block url="…">…</synced_block>` (close-agent only — 5 of them)** — these are
   **shared** Notion content (the §R MC Routing block + §CC capsule, synced to other pages).
   **Do NOT delete + recreate them** — that breaks the sync everywhere. Update the prose
   *around* them; leave each synced-block region in place. If a synced block's text itself
   changed, edit it inside the existing block.
3. **`<table>…</table>` tags** — the source renders tables as HTML-ish tables. Notion's
   editor accepts markdown pipe-tables on paste, but these are HTML tables; recreate them
   as Notion tables or paste the equivalent pipe-table.

## What changed (so you can focus your review)

**executor → 8.1.0-packet-runner** (§CONTRACT_CONFLICTS executor row): removed Run ID /
Worker ID / claim / lease / heartbeat / budget everywhere they were *required* (§0.SA.4,
§3.PF.2, §3.R envelope) → best-effort FOCUS + `observedLastEditedTime` (a change-detector,
not a lock); **new §3.MR** material-revision guard; **new §3.RS** FIRST_RUN/ALREADY_SATISFIED/
SAFE_RESUME/UNSAFE_AMBIGUOUS + the six-condition SAFE_RESUME gate; receipt swapped to full
`packet-runner-receipt-v1` YAML; worker mode writes **no** AI LOG / no close-agent; output
proposed only inside the reserved `## Packet Runner Output`; BLOCKED only when prereq+owner+
unblock known, else REVIEW. Session posture preserved verbatim.

**orchestrator → 7.1.0**: QUEUE = freshness-bounded certificate (stamp `Lifecycle Checked At`,
7-day expiry); known unmet prereq → **BLOCKED** (not QUEUE); explicit **Execution Class**
required (blank ⇒ REVIEW); authors the reserved empty `## Packet Runner Output`; Phase 5
telemetry **selective** (not "drain every payload"); sequential cross-packet.

**close-agent → 3.2.0**: **mode split** — INTERACTIVE (the current 7-phase chain, preserved),
WORKER (**skipped** — executor returns the receipt), CYCLE (reconcile receipts → attention-first
brief §8.6 → selective AI LOG §8.11/§8.19; suspends retro/skill-audit/blanket packet-finalize).

## Verify after pasting (per skill)
- [ ] Version string updated in **all** locations (MC JSON `version`, §M/§S metadata, §CC capsule, footer, evolution-log row).
- [ ] A dated evolution-log entry for this version is present.
- [ ] (close-agent) all 5 synced blocks still render as synced (not duplicated/plain).
- [ ] Mention-links resolve (no literal `<mention-page>` text left).
- [ ] Tables render.

When done, the live skill versions will match `config/routine.config.template.json → contract_versions`
(executor 8.1.0-packet-runner · orchestrator 7.1.0 · close-agent 3.2.0).

> Want the paste-optimized variants (mention tags → clickable URLs, synced blocks fenced + labelled)? Say the word and I'll generate them.
