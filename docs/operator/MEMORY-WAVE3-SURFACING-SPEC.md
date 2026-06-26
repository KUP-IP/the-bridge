# Unified Memory — Wave 3 Surfacing & Governance Spec (v2.0)

**Status:** v1.0 operator lock preserved; v2.0 incorporates codebase recon audit (2026-06-26)  
**Packet label:** PKT-MEM-115 (proposed)  
**Project:** The Bridge v3.8.x → v3.9.0 vertical — agent memory surfacing, routing integration, operator governance  
**Depends on:** Wave 1 (`MemoryStore`, `memory_remember`/`memory_recall`) + Wave 2 (`export`/`import`, `consolidationSweep`, `asyncComposition`, `MemoryAutoInjectClientStore`, client-source threading)  
**SSOT for:** implementation packets, test-floor raises, Settings UX, `fetch_skill` envelope extension  
**Supersedes:** v1.0 (same file — see §0 Audit critique)

---

## 0. Audit critique (v1.0 → v2.0)

Recon against live code (`MemoryModule`, `MemoryStore`, `StandingOrdersDelivery`, `SkillsModule`, `ServerManager`, `MemoryAgentTab`, standing orders v7.0.2). Items are ordered by severity.

| # | Severity | Finding | v1.0 assumption | v2.0 resolution |
|---|----------|---------|-----------------|-----------------|
| C1 | **Blocker** | `fetch_skill` returns cached envelopes **before** any post-processing (`SkillsModule` L312–314). A `scopedMemory` appendix baked into the cache would go stale as memories change; omitting it from cache means cache hits skip the appendix entirely. | Appendix wired inside handler before `cache.set` | **Post-cache merge:** always append `scopedMemory` after cache get/set, never include memory state in `cacheKey` |
| C2 | **Blocker** | `ServerManager` stdio initialize calls `asyncComposition(clientName: nil)` (L246) while tool dispatch uses synthetic `"stdio"` for `memory_remember` source (L322). Per-client Cursor inject cannot work on stdio until `clientName` is threaded on the stdio initialize path. | Cursor override works for all transports | Document stdio limitation in Phase A; add **stdio `clientName` pass-through** (use `"stdio"` or future initialize metadata) as a small seam fix in WP1 |
| C3 | **High** | WP3 claims `memory_recall` must add `source` — **`entryValue` already exposes `source`** (`MemoryModule` L267). Remaining work is `renderMemoryMarkdown` + Agent tab meta row only. | Net-new recall shape | Downscope WP3 to formatter + UI; one assertion test that `source` is present (likely already true) |
| C4 | **High** | `renderMemoryMarkdown` omits `source` and `createdAt` (only type, text, entity, useCount). Inject rows and `bridge://memory` inherit the gap. | WP3 covers this | Explicit shared row formatter used by inject, resource, and appendix |
| C5 | **High** | Keeper→scope map lists `project-keepr` implicitly via examples; **v7.0.2 standing orders removed inline keeper prose** — roster is live via `skills_routing_list`. `project-keepr` may still resolve as a skill but is no longer a routing entry point. | Static keeper table is authoritative | Scope map keys on **`fetch_skill` `name` param (parent slug)**; derive canonical rows from live `skills_routing_list` names; map `project-keepr` → same scopes as `focus-keepr` for backward compatibility |
| C6 | **High** | Appendix keyed on parent slug is **correct** for intent routing (`buildSkillResult` uses parent `skillConfig.name` even when a specialist body is swapped in). v1.0 did not document this invariant. | Unclear whether specialist envelope changes scope | Document: scope map uses **request parent**, not resolved specialist title |
| C7 | **Medium** | Entity hint regex `[a-z0-9-]{3,}` on full `intent` will false-positive on common tokens (`make`, `install`, `bridge`). | Minimal regex is sufficient | v2: extract entity only from **slug-like tokens after normalization**, denylist common verbs, prefer tokens matching known `entity` values in store (optional second pass) |
| C8 | **Medium** | Appendix promotion policy (`recall` use-promotes) vs handshake (`handshakeSlice` does **not** promote) is correct but unstated side effect: frequent `fetch_skill` re-routing will inflate `useCount` and salience. | Promotion is uniformly good | Keep promote on appendix; cap at 5 rows; document salience side effect in operator docs |
| C9 | **Medium** | D7 "keep both contradictions below Jaccard" is imprecise: **`remember` supersedes at Jaccard ≥ 0.72** within scope+entity. Recall shows multiple rows only when texts are *semantically* conflicting but lexically distinct. | Contradiction handling is recall-only | Clarify D7: near-dup write-time supersede vs recall-time multi-row presentation |
| C10 | **Medium** | Cursor seed `{"cursor": true}` has **no first-install migration** — `MemoryAutoInjectClientStore` returns empty dict on fresh install. UI "seed on first open" is fragile (Settings may never open). | Operator setup script is enough | Add **`seedDefaultsIfNeeded()`** on app launch (idempotent): global OFF, `cursor` → ON when override map empty |
| C11 | **Medium** | MCP `clientInfo.name` for Cursor is **assumed** `"cursor"` — not verified in repo. Mismatch would break seeded override. | `cursor` is canonical | Add Delivery-audit log line for observed `clientName` at initialize; document how to fix override key in Settings |
| C12 | **Medium** | Voice-memo `agent_memory` lane writes `type: reference` → **90-day unused tombstone** via `consolidationSweep`. Operators may not expect voice-captured facts to expire. | Lifecycle section is complete | Add operator-facing note in Memory Agent tab footer + spec §8; recommend `fact`/`preference` at commit time for durable voice captures (future voice-memo tweak — out of Wave 3 scope unless trivial) |
| C13 | **Low** | `memory_pin` MCP tool is optional for Wave 3 — **MEMORY-HUB + UI can call `MemoryStore.pin` directly**; `memory_forget` already exists for agents. | +1 tool required | **Split:** Phase A ships UI pin/forget via store; `memory_pin` MCP is Phase A optional / Phase B if agent ergonomics need it |
| C14 | **Low** | Agent tab empty state says **"read-only"** (`MemoryAgentTab` L105) — conflicts with planned pin/forget/inject controls. | UI work is additive | Update copy + empty-state layout as part of WP1/WP4 |
| C15 | **Low** | `bridge-keepr` in scope map is harmless but **not a normal `fetch_skill` parent** (standing-orders identity). | Listed as keeper | Keep `global` fallback; remove `bridge-keepr` row from map (dead entry) |
| C16 | **Low** | `staticFeatureModuleToolCount` = **187** today; optional `memory_pin` → 188 + `Version.swift` comment. | +1 always | Only bump if `memory_pin` ships |
| C17 | **Low** | Cloud agent / CI **cannot run `make test`** (no Swift on Linux). Floor raise must happen on Mac. | Tests listed generically | Phase C explicitly Mac-only verification |

**Net:** v1.0 direction is sound; v2.0 tightens transport seams, cache architecture, scope-map authority, promotion semantics, and scopes WP3/WP4 to match what code already does.

---

## 0.1 Executive summary (unchanged intent, revised execution)

Wave 3 makes **agent memory useful without handshake bloat**:

1. **Handshake auto-inject** — global OFF; per-client ON for Cursor (launch-seeded); Settings toggle; stdio `clientName` fix.
2. **Memory-rides-routing** — `scopedMemory` appendix on `fetch_skill`, **post-cache**, parent-slug scope map.
3. **Lifecycle** — keep launch sweep; no auto-TTL on `decision`/`preference`; document voice-memo `reference` behavior.
4. **Provenance** — finish `renderMemoryMarkdown` + UI (recall JSON already has `source`).
5. **Operator UI** — pin/forget + inject controls on Memory → Agent tab.
6. **Sync** — defer cloud; export/import remains migration seam.

**Explicit non-goals (Wave 3):** cloud sync, encryption-at-rest, operator text-edit CRUD, demote tiers, Jobs consolidation, Notion MEMORY DS bidirectional sync, NLP entity extraction.

---

## 0.2 Decision ledger (operator lock 2026-06-26, D7 clarified)

| ID | Decision | Locked resolution | v2.0 note |
|----|----------|-------------------|-----------|
| D1 | Auto-inject default | **OFF global** | unchanged |
| D2 | Per-client inject | **ON for `cursor`**, launch-seeded | + C10 migration, C11 verify client name |
| D3 | Memory-rides-routing | **Minimal `scopedMemory` on `fetch_skill`** | + C1 post-cache merge |
| D4 | Lifecycle TTL | **No default TTL** on `decision`/`preference`; `reference` 90d sweep | + C12 voice-memo note |
| D5 | Memory lanes | **Source-agnostic dedup** | unchanged |
| D6 | Provenance | **Thread MCP client into `source`**; surface in markdown + UI | recall JSON done (C3) |
| D7 | Contradictions | **Near-dup write: supersede at Jaccard ≥ 0.72**; recall may return multiple distinct rows — agent reconciles | clarified (C9) |
| D8 | Scope taxonomy | **Open-ended storage; documented canonical set** | map follows live roster (C5) |
| D9 | UI posture | **Pin + forget + inject toggles**; no text edit | unchanged |
| D10 | Sync | **Local-only** | unchanged |

---

## 1. Current baseline (recon-verified)

| Capability | Location | Wave 3 touch |
|------------|----------|--------------|
| SQLite + FTS5 + embeddings + salience | `MemoryStore.swift` | scope map helper; optional `memory_pin` MCP |
| `memory_remember` / `memory_recall` / `forget` / `export` / `import` | `MemoryModule.swift` | recall `source` ✅; formatter; optional `memory_pin` |
| Client `source` on remember | `MemoryModule.argumentsWithClientSource`, SSE + stdio dispatch | verify HTTP; fix stdio inject `clientName` |
| Handshake auto-inject | `StandingOrdersDelivery.asyncComposition` | UI + launch seed + stdio fix |
| `handshakeSlice` (no promote) | `MemoryStore.swift` L491 | unchanged |
| `bridge://memory` resource | `BridgeResources` + `memoryMarkdown()` | inherits new row formatter |
| Launch `consolidationSweep` | `AppDelegate` | doc comment only |
| Agent tab (read-only today) | `MemoryAgentTab.swift` | pin/forget/inject; copy fix |
| `fetch_skill` envelope + cache | `SkillsModule.swift` | post-cache `scopedMemory` |

**Storage:** `~/.config/notion-bridge/memory.sqlite` (relocates with `BRIDGE_CONFIG_PATH`).

---

## 2. Architecture — capture vs surface

```text
CAPTURE (explicit)                    SURFACE (passive)
─────────────────────                   ─────────────────
memory_remember                         handshake auto-inject (optional, no promote)
voice_memo agent_memory lane            bridge://memory (opt-in read, no promote)
                                        memory_recall (agent query, promotes)
                                        fetch_skill scopedMemory (NEW, promotes)
```

**Invariants:**
- No auto-capture from chat.
- Passive surfaces (`handshakeSlice`, `bridge://memory`) never use-promote.
- Active surfaces (`recall`, appendix) use-promote returned rows.

---

## 3. Work packages (v2.0)

### WP1 — Handshake auto-inject UI, launch seed, stdio fix (D1, D2)

**Goal:** Operator governs inject without `defaults write`; fresh policy = global OFF, Cursor ON; stdio clients can use per-client overrides.

#### 3.1 Launch seed (new — C10)

Idempotent on app launch (e.g. `AppDelegate` after store open):

```swift
// Pseudocode
if MemoryAutoInjectClientStore.shared.allOverrides().isEmpty
   && !BridgeDefaults.memoryHandshakeAutoInjectEffective {
    MemoryAutoInjectClientStore.shared.setOverride(true, forClient: "cursor")
}
```

Does not overwrite operator edits (non-empty override map skips seed).

#### 3.2 Settings UI (`MemorySurfacingSettingsCard` extracted from `MemoryAgentTab`)

| Control | Binds to |
|---------|----------|
| Handshake memory inject (global) | `BridgeDefaults.memoryHandshakeAutoInject` |
| Per-client overrides | `MemoryAutoInjectClientStore` |
| Helper text | Shows last observed MCP client names from Delivery audit (read-only, C11) |

Tri-state per client: **Inherit** (remove key) / **Force ON** / **Force OFF** — maps to absent/`true`/`false` in store (already supported).

#### 3.3 Stdio `clientName` seam (new — C2)

`ServerManager` stdio initialize path:

```swift
// Today: asyncComposition(clientName: nil)
// v2:    asyncComposition(clientName: "stdio")
```

Aligns with synthetic `"stdio"` already used for `memory_remember` source injection. Document that real per-client names require Streamable HTTP/SSE initialize with `clientInfo`.

#### 3.4 Inject content (unchanged algorithm)

1. `handshakeSlice(limit: 20)` — pinned first, salience; **no promote**
2. `MemoryRowFormatter.markdown(entries)` (shared with WP3)
3. Truncate to `memoryHandshakeTokenBudget` (2000 chars)
4. Append `## Memory` after standing orders + routing trailer

#### 3.5 Acceptance criteria

- [ ] Launch seed: fresh install → `cursor` override ON without opening Settings
- [ ] Global OFF + Cursor ON → HTTP Cursor sessions get `## Memory`; global OFF + no override → no block
- [ ] stdio with override `"stdio": true` receives inject (after C2 fix)
- [ ] `asyncComposition` OFF → byte-identical to `composition` (existing test)
- [ ] Optional: Delivery audit records `memoryInjected` + `clientName`

#### 3.6 Files

- `TheBridge/App/AppDelegate.swift` (seed)
- `TheBridge/Server/ServerManager.swift` (stdio clientName)
- `TheBridge/UI/Sections/MemorySurfacingSettingsCard.swift` (new)
- `TheBridge/UI/Sections/MemoryAgentTab.swift`
- `TheBridgeTests/StandingOrdersDeliveryTests.swift` (+inject override tests)

---

### WP2 — Memory-rides-routing (`scopedMemory`) (D3)

**Goal:** Task-scoped memory appendix on `fetch_skill` without extra tool calls or stale cache.

#### 3.7 Scope map (`MemoryRoutingScopeMap.swift`)

Keyed on **`fetch_skill` `name` parent slug** (before `/` child path). Align with live routing roster; legacy aliases preserved:

| Parent slug | Primary | Secondary |
|-------------|---------|-----------|
| `focus-keepr` | `project` | `global` |
| `project-keepr` | `project` | `global` |
| `people-keepr` | `people` | — |
| `mac-keepr` | `mac` | — |
| `notion-keepr` | `skill` | `project` |
| `time-keepr` | `time` | — |
| `skill-keepr` | `skill` | — |
| `executor` | `project` | `global` |
| *unknown* | `global` | — |

`bridge-keepr` omitted (not a fetch parent). Unknown parents → `global` only.

#### 3.8 Entity hint (revised — C7)

```text
1. Normalize intent (trim, lowercased).
2. Tokenize on whitespace/punctuation.
3. Keep tokens matching ^[a-z0-9-]{3,}$ EXCEPT denylist:
   make, install, copy, build, test, run, the, bridge, keep, fetch, skill, ...
4. If multiple candidates, prefer one that matches an existing live entity in mapped scope(s) (single SQLite lookup).
5. Else use first candidate; if none → no entity filter.
```

#### 3.9 Appendix builder (`MemoryRoutingAppendix.swift`)

```swift
// Pseudocode
let parent = parsedParentSlug(name)  // "mac-keepr/update" → "mac-keepr"
let scopes = MemoryRoutingScopeMap.scopes(for: parent)
let entity = await MemoryRoutingScopeMap.extractEntityHint(intent, scopes: scopes, store: store)
let query = intent?.trimmed ?? ""
var entries: [MemoryEntry] = []
for scope in scopes {
    entries += try await store.recall(query: query, scope: scope, entity: entity, limit: 3)
}
entries = dedupeById(entries).prefix(5)
// promotes via recall — document salience side effect (C8)
```

#### 3.10 Post-cache merge (critical — C1)

In `SkillsModule` handler, **after** `if let cached = await cache.get(cacheKey) { ... }` return path AND after fresh build:

```swift
result = await MemoryRoutingAppendix.attach(to: result, parent: parentSlug, intent: intentArg)
return result
// Do NOT include appendix in cacheKey or cached payload.
```

Plain cache hits and network misses both get fresh memory. Appendix omitted when zero hits.

#### 3.11 Envelope shape (additive)

```json
{
  "name": "mac-keepr",
  "content": "...",
  "scopedMemory": {
    "parent": "mac-keepr",
    "intent": "install Bridge to Applications",
    "scopesQueried": ["mac"],
    "count": 2,
    "markdown": "### Scoped memory (mac)\n- [fact] Use make install-copy … · source: cursor · 2026-06-26 · used 4×"
  }
}
```

#### 3.12 Dispatch contract addition

> After `fetch_skill(parent, intent:)`, read `scopedMemory.markdown` when present. Treat as grounding for **this sub-task only**; re-fetch when intent changes. Scope map uses the **parent** slug from `name`, not a resolved specialist title.

#### 3.13 Acceptance criteria

- [ ] Cache hit + memory insert afterwards → appendix reflects new row (proves post-cache)
- [ ] `fetch_skill('mac-keepr', intent: 'make install-copy')` returns appendix when mac memories exist
- [ ] `fetch_skill('focus-keepr', intent: 'triage stale projects')` queries `project` + `global`
- [ ] `project-keepr` alias still maps to `project` scope
- [ ] Zero hits → no `scopedMemory` key
- [ ] Hermetic tests with temp `MemoryStore` injected via test seam

#### 3.14 Files

- **New:** `MemoryRoutingScopeMap.swift`, `MemoryRoutingAppendix.swift`, `MemoryRowFormatter.swift`
- `SkillsModule.swift` (post-cache attach only)
- `TheBridgeTests/MemoryRoutingAppendixTests.swift` (new)
- `ToolAnnotations.swift` (`fetch_skill` description)

---

### WP3 — Provenance finish (D5, D6, D7) — downscoped

**Goal:** Visible provenance on all markdown surfaces; recall JSON already complete.

#### 3.15 Shared row formatter (`MemoryRowFormatter.swift`)

```markdown
- [fact] Use make install-copy for agent sessions · the-bridge · source: cursor · 2026-06-26 · used 4×
```

Used by: `renderMemoryMarkdown`, `scopedMemory.markdown`, `bridge://memory` body.

#### 3.16 Recall JSON

`entryValue` already includes `source` — add/keep one regression test; update tool description if needed.

#### 3.17 Agent tab meta row

Show `source` + short `createdAt` date beside scope/type badges.

#### 3.18 Acceptance criteria

- [ ] `renderMemoryMarkdown` includes `source` + date
- [ ] `bridge://memory` inherits formatter
- [ ] UI shows source + date
- [ ] D7 documented in tool descriptions (write-time supersede vs multi-row recall)

#### 3.19 Files

- `StandingOrdersDelivery.swift` (delegate to `MemoryRowFormatter`)
- `MemoryAgentTab.swift`
- `MemoryModuleTests.swift` (+1 source assertion)

---

### WP4 — Operator governance UI (D9)

**Goal:** Pin and forget without MCP round-trip.

#### 3.20 Pin / forget

| Action | Implementation |
|--------|----------------|
| Pin / Unpin | `MemoryStore.pin(id:_:)` direct from UI |
| Forget | `MemoryStore.forget(id:)` with confirm alert |

**Optional MCP `memory_pin`** (notify tier) — defer unless agent callers need it; UI does not require it (C13). If shipped: +1 tool, annotation, registry count 187→188.

#### 3.21 Acceptance criteria

- [ ] Pin survives relaunch; pinned sort first in recall, inject, appendix
- [ ] Forget tombstones; gone from list and export
- [ ] Pinned rows exempt from `consolidationSweep` (already true)
- [ ] Empty state copy no longer says "read-only"
- [ ] AX IDs: `BridgeAXID.Memory.agentPinButton`, `agentForgetButton`

#### 3.22 Files

- `MemoryAgentTab.swift`
- `BridgeAXID.swift`
- Optional: `MemoryModule.swift` (`memory_pin`)

---

### WP5 — Lifecycle confirmation (D4) — docs + tests

No algorithm change unless regression found.

| Mechanism | Behavior |
|-----------|----------|
| `handshakeSlice` / resource | No promote |
| `recall` / appendix | Promotes returned rows |
| `reference` 90d unused | Tombstone on launch sweep |
| `decision` / `preference` | Indefinite unless TTL or forget |
| Voice-memo `agent_memory` → `reference` | Subject to 90d sweep — document in UI (C12) |

Add cross-link doc comment on `consolidationSweep`.

---

### WP6 — Deferred (unchanged)

Cloud sync, encryption, operator CRUD, demote tiers, Jobs consolidation, Claude `MEMORY.md` unification, Notion MEMORY DS sync.

---

## 4. Implementation phasing (revised)

```text
Phase A — operator-facing, low risk
  WP1  inject UI + launch seed + stdio clientName
  WP3  MemoryRowFormatter + UI provenance
  WP4  pin/forget UI (no memory_pin unless trivial)

Phase B — fetch_skill hot path
  WP2  scope map + appendix + post-cache merge + dispatch contract

Phase C — Mac-only verification
  WP5  lifecycle audit
  Live smoke: Cursor inject, fetch_skill appendix, pin/forget
  Floor raise (+10–14 tests estimated)
```

**Merge order:** A → B. Phase B must not land without post-cache merge tests.

---

## 5. Test plan + floor

| Test file | New cases |
|-----------|-----------|
| `StandingOrdersDeliveryTests.swift` | formatter rows; inject ON with override; OFF byte-identical |
| `MemoryRoutingAppendixTests.swift` | scope map; entity denylist; post-cache freshness; empty omit |
| `MemoryModuleTests.swift` | recall `source` regression; pin round-trip (if MCP ships) |
| `MemoryAutoInjectClientStore` / seed | launch seed idempotency |

**Floor raise:** measure on Mac after `make test`; +10–14 net-new → update `scripts/test-floor-gate.sh`.

---

## 6. MCP tool inventory delta

| Tool | Wave 3 |
|------|--------|
| `memory_recall` | document `source` (already returned) |
| `memory_pin` | **optional** — UI uses store directly |

---

## 7. Risks + mitigations (updated)

| Risk | Mitigation |
|------|------------|
| Stale appendix in cache | Post-cache merge (C1) |
| Wrong Cursor client key | Launch seed + audit log of observed name (C11) |
| Entity false positives | Denylist + optional entity DB match (C7) |
| Salience inflation from routing | Cap 5 appendix rows; document promotion (C8) |
| Voice facts expire | Operator note; future type override at commit |
| stdio clients miss Cursor override | stdio uses `"stdio"` key; document HTTP for Cursor |

---

## 8. Packet breakdown

| Packet | Scope | Phase |
|--------|-------|-------|
| **PKT-MEM-115a** | WP1 + WP3 + WP4 | A |
| **PKT-MEM-115b** | WP2 post-cache appendix | B |
| **PKT-MEM-115c** | Mac verify + floor + CHANGELOG | C |

---

## 9. CHANGELOG entry (draft)

```markdown
## v3.9.0 — Unified Memory Wave 3 (surfacing + governance)

- Handshake memory inject — Settings toggle (global OFF); per-client overrides with Cursor launch-seeded ON; stdio clientName fix.
- Memory-rides-routing — `fetch_skill` returns optional `scopedMemory` appendix (post-cache; parent→scope map).
- Agent memory UI — pin/forget on Memory → Agent tab; provenance in inject, recall, and appendix rows.
- Lifecycle unchanged: `reference` 90d sweep + explicit TTL only.
```

---

*v2.0 — recon audit 2026-06-26. Operator decisions from v1.0 stand; implementation proceeds on PKT-MEM-115a with revisions above.*
