# Integration handoff — `integration/v3.7.7`

**Status:** assembled + gated, **NOT pushed / merged / tagged** (public release is operator-gated). HEAD `d9eac55`, branched off `origin/main` (`c39d9fa`).
**Gate:** `make build` 0 errors · `make test-floor` **2014 passed / 0 failed** (floor 1950) · 209 tools / 29 families (runtime-test-enforced) · 130 test entrypoints, none dropped.

## What's in it (14 candidate branches)
| Branch | What | QA verdict |
|---|---|---|
| securitygate | module-scoped Always-Allow + coalesced prompts + less-missable timeout | pass-with-concerns (medium) |
| securitygate-revoke-ui | view + per-module **revoke** of module grants; "tier via module grant" annotation | (10 unit tests) |
| axcrash | AX-traversal crash fix (main-thread + bounded) | pass-with-concerns |
| automation | bridge_settings_navigate / focus + screen/click coord fixes | pass |
| buildtools | swift_build / swift_test over bg_process | pass |
| notionwrite | in-place page edit + bulk block delete + comment auto-chunk | pass-with-concerns |
| resultsize | fetch_skill partial + projection/pageSize controls | pass |
| permissions | Reminders/Calendar grant rows + permissions_status | pass |
| credentials | alias normalize + sentinel flag + idempotent-read retry | pass-with-concerns |
| session | server-side MCP session persistence/resume (partial) | pass-with-concerns |
| sparkle-atomic-install | graceful icon degradation + staged-update validator | (15 tests) |
| playbook / design-decouple / operator-runbooks | docs/design only | pass |

## Operator next steps (the true close — all operator-gated)
1. **Review `integration/v3.7.7`** → merge to `main` → **tag** (suggest `v3.7.7`) → `release.yml` builds/notarizes/publishes the appcast.
2. **Sparkle (932):** blast-radius confirmed **dev-only** (the `install-copy`↔Sparkle race; users on a clean DMG update are unaffected). The graceful-degradation fix is folded in. Residual to Done = a live cross-version update E2E.
3. **Cloud sprint:** run `docs/operator/cloud-deploy-runbook.md` + `deploy.sh` (Cloudflare KV+secrets+deploy) + WorkOS tenant + domain → closes WS-A/B, then 810, then live-E2E WS-F/D/G, then submit 801. See `OPERATOR-ACTION-PLAN.md`.
4. **968 Live OS gates:** grant Reminders/Calendar TCC + verify (`live-os-gates-tcc.md`).
5. **965 Unified Memory:** answer `v3.7.7-memory-design-questions.md` before scoping.

## Flagged for a focused follow-up (NOT fixed here — QA rated all "merge"; not churned into the clean integration)
- **securitygate — lost-wakeup race (low-prob, real):** in `SecurityGate.swift` requestViaNotification, a coalesced waiter calls `reserveCoalesced` before `parkCoalescedWaiter`; if the owner resolves in that gap the waiter can miss the wakeup. Fix = park the continuation before/atomically with reserving. Concurrency-delicate — verify with a stress test.
- **securitygate — security-posture broadening (by design):** one "Always Allow" now writes `moduleTierOverrides[module]=notify`, auto-approving every non-`neverAutoApprove` sibling in that module (e.g. consenting to `snippets_update` also auto-approves `snippets_import`/`export`). This is what FB-5 requested; the **revoke-ui** mitigates it (visible + revocable). Decide if the default should be per-tool with an explicit "apply to module" opt-in.
- **credentials — dead/wrong NOTION alias:** `CredentialAliasNormalizer` maps `NOTION_*` → service `notion`/account `notion`, but the Notion token is stored under `com.notionbridge`/`notion_api_token`. The alias silently resolves to an empty location. Fix = correct the mapping or drop the NOTION aliases.
- **credentials — alias-shadowing:** `looksLikeAlias` treats *any* SCREAMING_SNAKE `*_KEY`/`*_TOKEN` as an alias, shadowing a user's literal same-named service. Fix = restrict to the documented `canonicalAliasMap` (matches the code's own stated intent) + update the suffix tests.

## On-device
- **revoke-ui visual:** logic is unit-tested (10 tests, green). The on-device eyeball was **deferred** — the LSUIElement Settings window wouldn't open reliably via raw AX this session (the exact friction `automation`'s `bridge_settings_navigate` addresses). Repro at review: `defaults write kup.solutions.notion-bridge com.notionbridge.moduleTierOverrides -dict snippets notify`, relaunch, Settings → Tools → "Module Grants" section.
- **Running app:** `/Applications/The Bridge.app` is currently this **integration build** (installed for verification; version string still 3.7.6, no branch bumped it). Reinstall released `main` to revert, or keep it (it's a strict superset + has the Sparkle fix).

## Dispositioned this session
- **FB-1 (943) / FB-4 (946):** Declined — harness-side (Claude Code MCP transport), not fixable in-repo; file upstream.
- 6 v3.7 packets signed off to Done (prior Reflow); the cloud cluster held in REVIEW (blocked on operator infra).
