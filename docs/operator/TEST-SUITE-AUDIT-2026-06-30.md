# TEST-SUITE-AUDIT — 2026-06-30

**Static tools (annotation catalog):** 199
**BridgeConstants.staticFeatureModuleToolCount:** 197 (+2 triage)

## Summary

| Layer | Status |
|-------|--------|
| ToolAnnotationAuditTests | All static tools |
| VoiceMemoSuiteAuditTests | 10 voice_memo_* |
| DevSuiteAuditTests | dev/gh/git/code |
| MessagesSuiteAuditTests | messages_* |
| ToolSurfaceCoverageAuditTests | quoted name in tests |
| SettingsUIValidationHarness | memory + datasources in pkt1005 |

## Sprint-critical gaps closed

- voice_memo_triage_open / voice_memo_triage_await — registered + annotated + VoiceMemoSuiteAuditTests
- Memory pkt1005 — memory + datasources sections in shell script
- Compound Memory anchors — MemoryNavigationAnchor + bridge_settings_navigate resolved JSON

## Tool inventory (sample — full list in catalog)

- `bridge_focus_settings` — module test ref: yes
- `bridge_open_settings` — module test ref: yes
- `bridge_settings_navigate` — module test ref: yes
- `bridge_status` — module test ref: yes
- `memory_export` — module test ref: yes
- `memory_forget` — module test ref: yes
- `memory_import` — module test ref: yes
- `memory_recall` — module test ref: yes
- `memory_remember` — module test ref: yes
- `memory_update` — module test ref: yes
- `voice_memo_commit` — module test ref: yes
- `voice_memo_get` — module test ref: yes
- `voice_memo_list` — module test ref: yes
- `voice_memo_process` — module test ref: yes
- `voice_memo_review_dismiss` — module test ref: yes
- `voice_memo_review_list` — module test ref: yes
- `voice_memo_review_resolve` — module test ref: yes
- `voice_memo_transcript_refresh` — module test ref: yes
- `voice_memo_triage_await` — module test ref: yes
- `voice_memo_triage_open` — module test ref: yes

## Known follow-ups

- job_* tools: referenced via JobsModuleTests patterns; meta-audit uses quoted-name scan
- Layout wireframe (Option B recommended): pending operator approval — see docs/operator/MEMORY-PROCESS-LAYOUT-WIREFRAMES.md
