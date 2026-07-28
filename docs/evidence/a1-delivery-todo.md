# A1 delivery todo

- [x] Resolve governance route stack and validate the live A1 packet/dependencies.
- [x] Qualify base `01fd3984b91ca3c9e3ff16160d2a80a3d42f6261` with green remote CI.
- [x] Create isolated worktree `a1-canonical-packet-registry` from the verified base.
- [x] Canonicalize `packet`/`session` identity without a second data source or cache.
- [x] Preserve a genuine Sessions entity when it coexists with canonical PACKETS.
- [x] Make packet lifecycle removal atomically clear canonical and legacy packet-shaped bindings only.
- [x] Add the versioned read-only `packet_registry_preflight` production seam and tool.
- [x] Retain live schema option/relation metadata and exact drift classifications.
- [x] Add deterministic mission serialization, revision preparation, hashing, and hydration evidence.
- [x] Make mission normalization code-fence-safe and fail closed on incomplete evidence.
- [x] Add focused hermetic coverage and update tool inventory expectations.
- [x] Repair legacy introspection persistence so aliasing cannot create duplicate config entries.
- [x] Authoritative Bridge-host compile succeeded.
- [x] Full behavioral suite: 3,518 passed, 0 failed.
- [x] Test floor: 3,518 passed, 0 failed; gate PASS.
- [x] Bind the test floor to 3,518 with append-only provenance.
- [x] Apply the additive PACKETS schema migration (`Mission Revision`, `Mission Hash`).
- [x] Rebind the existing `session` registry row in place; fully bound 24/24, no second packet row.
- [x] Verify `session` and `packet` hydrate the same live A1 row.
- [x] Run the exact production preflight evaluator against the captured post-migration live snapshot: PASS, 0 defects.
- [x] Complete three independent review passes; final lifecycle review verdict APPROVE with no required fixes.
- [ ] Freeze final diff and commit the reviewable A1 candidate.
- [ ] Rerun exact-SHA test floor and exact-SHA captured-live preflight.
- [ ] Write A1 REVIEW receipt and stop at Ship Gate.

## Environment note

The fresh Codex worker could not compile inside its restricted sandbox because the module cache was denied and dependency DNS was unavailable. The same source compiled successfully through the Bridge host with the repository's normal dependency/cache surface; this was an environment defect, not a product failure.
