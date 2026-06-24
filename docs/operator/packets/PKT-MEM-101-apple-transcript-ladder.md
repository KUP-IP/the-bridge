# PKT-MEM-101 — Apple tsrp Transcript Ladder

**Wave:** 1 (parallel)  
**Class:** Standard  
**Spec:** `docs/operator/MEMORY-HUB-EXECUTION-SPEC.md` §3, Appendix A  
**Branch:** `feat/pkt-mem-101-apple-transcript` off `origin/main`

---

## Objective

Implement Apple Voice Memo embedded transcript extraction and wire the transcription ladder so Bridge prefers cached sidecar → Apple tsrp → Parakeet fallback.

## Scope

**IN:**
- `AppleVoiceMemoTranscriptExtractor` (or equivalent) reading `tsrp` from `.m4a` / `.qta`
- `VoiceMemoDiscovery.resolveTranscript(for:)` ladder per spec §3
- Sidecar write + `transcript.meta.json` with `{source, extractedAt, charCount, forced?}`
- Update `voice_memo_list` to expose `transcriptSource` (apple | parakeet | sidecar | none)
- Fix stale `voice_memo_process` tool description (remove "Wave 1 sidecar only")
- Unit tests with fixture bytes (minimal tsrp JSON) + hermetic discovery tests
- Quality heuristic: optional Parakeet when Apple text suspiciously short

**OUT:**
- Settings UI changes (PKT-MEM-102)
- Review dispositions (PKT-MEM-103)
- Notifications (PKT-MEM-104)

## Definition of Done

- [ ] Operator memo `20260613 120059-BC1F09DE.m4a` resolves transcript via Apple without Parakeet when sidecar absent
- [ ] Existing sidecar cache wins (no re-extract)
- [ ] Parakeet runs only when Apple missing/empty or heuristic triggers / force flag
- [ ] `make test` green; floor raised if net-new tests added
- [ ] `ToolAnnotationCatalog` updated if tool schema changes

## QA Checklist

- [ ] Delete sidecar for test memo → process → Apple sidecar created with `source: apple`
- [ ] `voice_memo_list` shows correct `transcriptSource`
- [ ] Parakeet toggle OFF + no Apple → review reason "no transcript"
- [ ] No concurrent transcribe+route in processor (sequential preserved)

## Execution Directives

- Reuse `VoiceMemoDiscovery.homeRoot` for hermetic tests
- Byte-scan fallback for `{"attributedString":` if atom walk fails
- Keep FluidAudio lazy singleton; don't load Parakeet when Apple succeeds
- Match existing Swift 6 actor patterns; `nonisolated(unsafe)` only where NIO/FluidAudio requires

## Dependencies

None (Wave 1 parallel)

## Verification command

```bash
make test && make test-floor
```
