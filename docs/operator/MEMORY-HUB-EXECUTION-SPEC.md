# Memory Hub — Validated Execution Spec (v1.0)

**Status:** Implementation-ready (orchestrator-validated 2026-06-24)  
**Project:** The Bridge v3.9.x vertical — Voice capture → triage → three memory surfaces  
**SSOT for:** executor sub-agents · Settings UX · transcription ladder · review dispositions

---

## 0. Validation summary (assumptions tested)

| Assumption | Verdict | Evidence |
|---|---|---|
| "Transcription didn't work" on 20260613 memo | **FALSE (UX bug)** | Apple `tsrp` embedded in `.m4a`; Parakeet wrote 3825-byte `.txt` sidecar. Failure was **routing → review**, not ASR. |
| Apple transcripts available on disk | **TRUE (undocumented API)** | `tsrp` atom JSON in `moov/trak/udta/tsrp`; no separate file; `CloudRecordings.db` has metadata not transcript text. |
| Bridge already uses Apple transcripts | **FALSE** | `VoiceMemoDiscovery.loadTranscriptSidecar` reads **only** adjacent `.txt`. `hasTranscript` in `voice_memo_list` ignores Apple. |
| Review belongs in Advanced | **FALSE (product)** | `AdvancedSection.voiceMemosReviewCard` — operator-confirmed wrong IA. |
| Data Sources should absorb Memory | **PARTIAL** | Registry config stays in **Data Sources**. Capture inbox + agent memory + Notion preview belong in **Memory** (new section). |
| `memory_remember` has UI | **FALSE** | `MemoryStore` at `~/.config/notion-bridge/memory.sqlite` — MCP only (`docs/operator/v3.7.7-memory-design-questions.md`). |
| Review has dispositions beyond dismiss | **FALSE** | Only `voice_memo_review_dismiss`; no resolve-with-action, no retry-routing tool. |
| Review entries expire | **FALSE** | `VoiceMemoReviewStore` — pending forever until dismiss. |
| Processed = transcribed | **FALSE** | `VoiceMemoProcessedStore` marks only when **executed** outcomes exist; review queue leaves memo re-eligible. |
| Tool docs match Wave 2 | **FALSE (stale)** | `voice_memo_process` metadata still says "transcript must exist as .txt sidecar in Wave 1". |
| Test floor baseline | **2270** | `scripts/test-floor-gate.sh` FLOOR=2270; must raise only with net-new tests. |

---

## 1. Product goal (market framing)

**Operator promise:** "I speak → Bridge captures → I triage once → durable memory lands where it belongs (Notion, agent, reminders, registry) without babysitting Advanced settings."

**Success metrics (ship gate):**
- Median voice memo: **zero Advanced-tab visits** for triage
- Transcription: **≥95%** of iCloud memos get text without manual sidecar (Apple + Parakeet ladder)
- Review inbox: **<30s** to disposition a memo (Memory Keep / Dismiss / Retry route)
- No duplicate Notion Memory rows on re-run (idempotency preserved)

---

## 2. Information architecture (LOCKED)

### New Settings section: **Memory** (`SettingsSection.memory`)

| Tab | Content | Data source |
|---|---|---|
| **Inbox** (default) | Voice memo review queue + transcript preview + dispositions | `~/Library/Application Support/The Bridge/voice-memos/review.json` + sidecars |
| **Notion** | Recent Memory registry rows (read-through); link to Notion | `registry_list entity=memory` |
| **Agent** | SQLite agent memories (scope/type filters, pin/forget) | `~/.config/notion-bridge/memory.sqlite` via `MemoryStore` |

**Data Sources** (`SettingsSection.datasources`): **unchanged scope** — entity → Notion DS → property map, introspect, cache TTL. Add cross-link chip: "Memory entity → open Memory pane".

**Advanced:** Local Models (Parakeet/Gemma) **stays** — infrastructure, not content. **Remove** `voiceMemosReviewCard`.

**Sidebar order (after Jobs):** Commands · Skills · Jobs · Tools · Security · Connection · **Memory** · Data Sources · Advanced

### MCP / deep-link

- `bridge_settings_navigate(section: "Memory", anchor: "inbox"|"notion"|"agent")`
- Legacy alias: `voice-memos` → Memory/Inbox (deprecate Advanced anchor)

---

## 3. Transcription ladder (LOCKED)

Priority order in `VoiceMemoDiscovery.resolveTranscript(for:)`:

```
1. Bridge sidecar (.txt) — canonical cache if non-empty
2. Apple tsrp atom — extract, write sidecar + transcript.meta.json {source:"apple", extractedAt, charCount}
3. Parakeet (FluidAudio) — only if 1–2 fail/empty AND toggle ON; write sidecar {source:"parakeet"}
4. nil → review reason "no transcript" (distinct from "unclassified")
```

**Settings toggles** (Local Models or Memory → Inbox footer):
- `Prefer Apple transcript` — default **ON**
- `Parakeet fallback` — default **ON**
- `Re-transcribe` — per-memo action only (force Parakeet, overwrite sidecar with `{source:"parakeet", forced:true}`)

**Quality heuristic (Parakeet fallback even when Apple exists):** Only if Apple text length `< max(80, 0.05 × audioDurationSec × 15)` chars — tunable constant in tests.

**Do NOT rely on Apple alone:** Apple breaks, truncates, mis-hears (`outposting` vs `not posting` on live memo). Parakeet remains override path.

**RAM discipline (M1 16GB):** Transcribe (Apple sync extract OR Parakeet) **then** route (Gemma) — never concurrent.

---

## 4. Review UX & dispositions (LOCKED)

### Inbox row fields

- Title · recorded date · **transcript source badge** (Apple | Parakeet | Sidecar | Missing)
- **Status:** Transcribed · Routing failed · Low confidence · No transcript
- Confidence · suggested lane · reason
- Expandable full transcript · Reveal in Finder

### Dispositions

| Action | Backend | Marks processed? |
|---|---|---|
| **File as Memory** | `registry_create` + `notion_blocks_append` transcript | Yes |
| **Add reminder** | `reminders_create` | Yes |
| **Agent should know** | `memory_remember` | Yes |
| **Registry update…** | picker → `registry_update` | Yes |
| **Retry routing** | re-run Ollama/heuristics only (no re-transcribe) | No (unless auto-executes) |
| **Dismiss** | `voice_memo_review_dismiss` | No |
| **Mark handled (no write)** | `voice_memo_review_resolve` + `processed.json` | Yes |

New MCP tools (Wave 2): `voice_memo_review_resolve` (action + fields), optional `voice_memo_transcript_refresh` (force ladder step).

### TTL (Wave 2)

| State | TTL | Action |
|---|---|---|
| `pending` | 30 days | auto-dismiss + single notify |
| `dismissed` | 7 days | purge from manifest |
| `resolved` | immediate | remove from pending |

Implement via launch/on-wake sweep (reuse `JobsReconciler` pattern), not LaunchAgent job initially.

---

## 5. Notifications (LOCKED)

**Replace** generic "open Advanced" copy.

| Condition | Title | Body | Tap action |
|---|---|---|---|
| Review queued | Voice Memos need triage | "N transcribed, need disposition" | `bridge_settings_navigate(Memory, inbox)` + focus |
| No transcript | Voice Memos skipped | "N missing transcript" | Memory/Inbox filtered view |
| Routing failed | Voice Memos routing failed | detail count | Memory/Inbox |

**Phase 2:** UNNotificationCategory quick actions (File as Memory, Dismiss) — requires app delegate wiring; defer to PKT-MEM-104+.

---

## 6. Current system state (code map)

| Component | Path |
|---|---|
| Voice discovery | `TheBridge/Modules/VoiceMemo/VoiceMemoDiscovery.swift` |
| Processor | `TheBridge/Modules/VoiceMemo/VoiceMemoProcessor.swift` |
| Review store | `TheBridge/Modules/VoiceMemo/VoiceMemoReviewStore.swift` |
| Notifier | `TheBridge/Modules/VoiceMemo/VoiceMemoNotifier.swift` |
| Parakeet | `TheBridge/Modules/VoiceMemo/VoiceMemoTranscriber.swift` |
| Agent memory | `TheBridge/Modules/MemoryStore.swift`, `MemoryModule.swift` |
| Registry Memory entity | `Modules/Registry/*`, bound in live `registry.json` |
| Settings sections | `UI/SettingsWindow.swift`, `SettingsWindow+Sections.swift` |
| Advanced review card | `UI/Sections/AdvancedSection.swift` (REMOVE) |
| Data Sources | `UI/Sections/DataSourcesSection.swift` (unchanged scope) |
| Settings nav MCP | `Modules/BridgeAutomationModule.swift` |
| AX harness | `Modules/SettingsUIValidationHarness.swift` |

---

## 7. Wave plan & packet dispatch

### Wave 1 (parallel — no cross-deps)

| Packet | Class | Outcome |
|---|---|---|
| **PKT-MEM-101** | Standard | Apple `tsrp` extractor + transcription ladder + tests |
| **PKT-MEM-102** | Standard | `SettingsSection.memory` + Inbox UI P0 + remove Advanced card |

### Wave 2 (sequential after Wave 1)

| Packet | Class | Outcome |
|---|---|---|
| **PKT-MEM-103** | Standard | Review resolve tools + TTL sweep + disposition wiring |
| **PKT-MEM-104** | Standard | Notification/deep-link + Agent/Notion tabs + AX harness |

### Wave 3 (deferred)

- Notification quick actions (UNUserNotificationCenter categories)
- Consolidation job for agent memory tiers (`v3.7.7-memory-design-questions.md`)
- `registry_remove_entity` / batch curator go-live UX

---

## 8. Material decisions (pre-resolved — do not re-litigate in packets)

| Decision | Resolution |
|---|---|
| Memory vs Data Sources merge | **Separate section**; DS stays schema/registry |
| Apple-first transcription | **Yes**, with Parakeet fallback + manual re-transcribe |
| Default routing model | `gemma4:12b` (M1 16GB) — already seeded in `BridgeDefaults` |
| Review UI review class | **REVIEW-FIRST** — operator approves disposition UX in Settings |
| Min macOS | macOS 26+ (project baseline); Apple tsrp requires Voice Memos 15+ behavior |

---

## 9. Verification gates (global)

Every packet must:
1. `make test` green; raise `FLOOR=` only by net-new tests with provenance comment
2. Update `ToolAnnotationCatalog` for new MCP tools
3. Update stale `voice_memo_process` tool description when transcription changes
4. `SettingsUIValidationHarness` entries for Memory section
5. No regression: `job_run` on paused jobs still works (`allowPaused: true`)

---

## 10. Known imperfections owned by this spec

1. **`hasTranscript` lie** — lists false until sidecar exists even when Apple embedded — **PKT-MEM-101 fixes**
2. **Stale MCP tool metadata** — Wave 1 sidecar wording — **PKT-MEM-101**
3. **Review ≠ transcription failure** — conflated in notify copy — **PKT-MEM-102/104**
4. **No resolve path** — dismiss-only — **PKT-MEM-103**
5. **237+ memos without sidecar** — Apple ladder unlocks batch without 2min Parakeet each — **PKT-MEM-101**
6. **Duplicate Memory rows** — idempotency by memo id; UI should warn on force re-file — **PKT-MEM-103**
7. **Executor packets live in repo** — Notion PACKETS DS sync is operator follow-up, not blocking code execution

---

## Appendix A — Apple tsrp extraction reference

- Atom path: `moov/trak/udta/tsrp` (also byte-scan fallback for `{"attributedString":`)
- Formats: interleaved runs + attributeTable (see uasi/extract-apple-voice-memo-transcript)
- `.qta` containers: may use `moov.meta.ilst` / `com.apple.VoiceMemos.tsrp` — handle in 101 if tests find qta samples

---

## Appendix B — Live operator memo (20260613)

- Path: `~/Library/Group Containers/.../20260613 120059-BC1F09DE.m4a`
- Apple transcript: present (`attributedString` at byte ~2.8MB)
- Parakeet sidecar: 3825 bytes (shorter than Apple)
- Review reason: `parser could not classify` — expected without "keep this" phrasing
