# Unified Memory — Wave 3 Surfacing & Governance Spec (v1.0)

**Status:** Operator-approved recommendations locked 2026-06-26  
**Packet label:** PKT-MEM-115 (proposed)  
**Project:** The Bridge v3.8.x → v3.9.0 vertical — agent memory surfacing, routing integration, operator governance  
**Depends on:** Wave 1 foundation (`MemoryStore`, `memory_remember`/`memory_recall`) + Wave 2 (`export`/`import`, `consolidationSweep`, `asyncComposition`, client-source threading seam)  
**SSOT for:** implementation packets, test-floor raises, Settings UX, `fetch_skill` envelope extension

---

## 0. Executive summary

Wave 3 makes **agent memory useful without handshake bloat**:

1. **Handshake auto-inject** — global OFF; per-client ON for Cursor; Settings toggle (no UserDefaults surgery).
2. **Memory-rides-routing** — minimal appendix on `fetch_skill` (keeper→scope map + intent query).
3. **Lifecycle** — keep current launch sweep; no auto-TTL on `decision`/`preference`.
4. **Provenance** — one shared brain; finish threading `source` + surface it in recall/UI.
5. **Operator UI** — pin/forget on Memory → Agent tab; inject controls on same pane.
6. **Sync** — defer cloud; `memory_export`/`memory_import` remain the migration seam.

**Explicit non-goals (Wave 3):** cloud sync, encryption-at-rest, operator text-edit CRUD, demote tiers (hot/warm/cold), background Jobs consolidation, Notion MEMORY DS bidirectional sync.

---

## 0.1 Decision ledger (operator lock 2026-06-26)

| ID | Decision | Locked resolution | Rationale |
|----|----------|-------------------|-----------|
| D1 | Auto-inject default | **OFF global** | Handshake already carries standing orders + routing index; global inject adds variable tokens every session |
| D2 | Per-client inject | **ON for `cursor`** (override), others inherit global | Cursor is primary builder surface; Claude web / ChatGPT need less Mac-scoped noise |
| D3 | Memory-rides-routing | **Ship minimal** on `fetch_skill` | Highest leverage: task-scoped grounding without agent remembering to `memory_recall` |
| D4 | Lifecycle TTL | **No default TTL** on `decision`/`preference`; keep `reference` 90d sweep + explicit `ttlSeconds` | Long-lived operator truths must not silently expire |
| D5 | Memory lanes | **Source-agnostic dedup** (one operator brain) | Matches KEEP OS trajectory; Cursor + Claude collapse duplicates |
| D6 | Provenance | **Thread real MCP client into `source`** when caller omits it; show at recall + UI | Audit trail without fragmenting memory |
| D7 | Contradictions | **Keep both** below Jaccard threshold; surface both with `source` + date at recall | Agent asks once; operator supersedes via new `memory_remember` |
| D8 | Scope taxonomy | **Open-ended storage; canonical documented set** | `people \| project \| mac \| time \| skill \| global` — agents should use consistently |
| D9 | UI posture | **Pin + forget + inject toggles** on Memory → Agent; no text edit | Matches Memory Hub trust posture (PKT-MEM-106) |
| D10 | Sync | **Local-only**; export/import for backup | Defer cloud until multi-Mac or sale-ready privacy review |

---

## 1. Current baseline (what already ships)

| Capability | Location | Wave 3 touch |
|------------|----------|--------------|
| SQLite + FTS5 + embeddings + salience | `MemoryStore.swift` | Add `memory_pin` MCP tool; scope map helper |
| `memory_remember` / `memory_recall` / `forget` / `export` / `import` | `MemoryModule.swift` | Recall returns `source`; new `memory_pin` |
| Client `source` injection on remember | `MemoryModule.argumentsWithClientSource`, `SSETransport` + `ServerManager` | Verify all transports; document |
| Handshake auto-inject (flag only) | `StandingOrdersDelivery.asyncComposition` | UI for flags; seed Cursor override |
| `bridge://memory` resource | `BridgeResources` + `memoryMarkdown()` | Unchanged |
| Launch consolidation sweep | `AppDelegate` → `consolidationSweep()` | Unchanged |
| Agent tab (read-only list) | `MemoryAgentTab.swift` | Add pin/forget/inject controls |
| `fetch_skill` envelope | `SkillsModule.buildSkillResult` | Add optional `scopedMemory` key |

**Storage paths:**
- DB: `~/.config/notion-bridge/memory.sqlite` (relocates with `BRIDGE_CONFIG_PATH`)
- Not the same as Notion MEMORY DS or Claude Code `MEMORY.md` files

---

## 2. Architecture — capture vs surface

```text
CAPTURE (explicit)                    SURFACE (passive)
─────────────────────                   ─────────────────
memory_remember                         handshake auto-inject (optional)
voice_memo agent_memory lane            bridge://memory (opt-in read)
                                        memory_recall (agent query)
                                        fetch_skill scopedMemory (NEW)
```

**Invariant:** The Bridge never auto-captures from chat. Capture requires `memory_remember` (agent) or approved voice-memo commit.

---

## 3. Work packages

### WP1 — Handshake auto-inject UI + defaults (D1, D2)

**Goal:** Operator can govern inject without `defaults write`; fresh policy = global OFF, Cursor ON.

#### 3.1 Settings UI (`MemoryAgentTab` or new `MemorySurfacingCard`)

Add to **Settings → Memory → Agent** (top card, above list):

| Control | Type | Binds to |
|---------|------|----------|
| Handshake memory inject (global) | Toggle | `BridgeDefaults.memoryHandshakeAutoInject` |
| Per-client overrides | Compact list editor | `MemoryAutoInjectClientStore` |
| Seed row: `cursor` → ON | Pre-filled on first open if map empty | `setOverride(true, forClient: "cursor")` |

**Per-client editor UX (minimal):**
- Text field: client name (from MCP `clientInfo.name`, e.g. `cursor`, `claude-code`)
- Tri-state: Inherit global / Force ON / Force OFF
- Stored as `Bool` override only when not inheriting

#### 3.2 Inject resolution (unchanged logic, document)

```text
shouldInject(clientName):
  if perClientOverride(clientName) != nil → use override
  else → BridgeDefaults.memoryHandshakeAutoInjectEffective
```

#### 3.3 Inject content (unchanged algorithm, document)

1. `handshakeSlice(limit: 20)` — pinned first, then salience
2. `renderMemoryMarkdown(entries)`
3. Truncate to `memoryHandshakeTokenBudget` (2000 chars ≈ 500 tokens) in salience order
4. Append under `## Memory` after standing orders + routing trailer

#### 3.4 Acceptance criteria

- [ ] Global toggle OFF → `asyncComposition` byte-identical to `composition` (existing test pattern)
- [ ] Global OFF + Cursor override ON → Cursor sessions get `## Memory` block; others do not
- [ ] Toggle survives relaunch; no UserDefaults key knowledge required
- [ ] Delivery audit line: `memoryInjected: true/false, tokenEstimate: N` (optional telemetry)

#### 3.5 Files

- `TheBridge/UI/Sections/MemoryAgentTab.swift` (or extract `MemorySurfacingSettingsCard.swift`)
- `TheBridge/Core/BridgeDefaults.swift` (no schema change)
- `TheBridge/Modules/StandingOrders/StandingOrdersDelivery.swift` (telemetry only, if added)
- `TheBridgeTests/MemoryModuleTests.swift` (+2 UI-adjacent store tests if no View tests)

---

### WP2 — Memory-rides-routing on `fetch_skill` (D3)

**Goal:** When an agent loads a keeper skill, receive a small, task-scoped memory appendix without a separate `memory_recall` call.

#### 3.6 Keeper → scope map (canonical)

New pure enum/module: `MemoryRoutingScopeMap.swift`

| Keeper slug (`fetch_skill` parent) | Primary scope | Secondary scope |
|-----------------------------------|---------------|-----------------|
| `focus-keepr` | `project` | `global` |
| `people-keepr` | `people` | — |
| `mac-keepr` | `mac` | — |
| `notion-keepr` | `skill` | `project` |
| `time-keepr` | `time` | — |
| `skill-keepr` | `skill` | — |
| `bridge-keepr` | `global` | — |
| `executor` | `project` | `global` |
| *unknown parent* | `global` | — |

**Entity extraction (minimal):** If `intent` matches a slug-like token (`[a-z0-9-]{3,}`) after normalization, pass as `entity` filter for primary scope recall. No NLP — regex only.

#### 3.7 Recall query for appendix

```swift
// Pseudocode — lives in MemoryRoutingAppendix.build(parent:intent:)
let scopes = MemoryRoutingScopeMap.scopes(for: parentSlug)
let entity = MemoryRoutingScopeMap.extractEntityHint(from: intent)
let query = intent.trimmed.isEmpty ? "" : intent  // FTS when non-empty
var entries: [MemoryEntry] = []
for scope in scopes {
    entries += try await store.recall(query: query, scope: scope, entity: entity, limit: 3)
}
entries = dedupeById(entries).prefix(5)
```

**Promotion policy:** Appendix recall **does promote** (same as `memory_recall`) — routed memories are actively used.

#### 3.8 Envelope extension (additive)

Add optional key to `fetch_skill` success object:

```json
{
  "name": "mac-keepr",
  "content": "...",
  "scopedMemory": {
    "parent": "mac-keepr",
    "intent": "install Bridge to Applications",
    "scopesQueried": ["mac"],
    "count": 2,
    "markdown": "### Scoped memory (mac)\n- [fact] Use make install-copy for agent sessions · the-bridge · source: cursor · used 4×\n..."
  }
}
```

- Omit `scopedMemory` entirely when zero hits (no empty shell)
- `markdown` uses same row format as `renderMemoryMarkdown` plus `source:` segment
- **Byte-stable:** existing keys unchanged; consumers ignore unknown keys

#### 3.9 Agent protocol (dispatch contract addition)

Append to `SkillsModule.dispatchContract` (or standing orders § Routing):

> After `fetch_skill(parent, intent:)`, read `scopedMemory.markdown` when present and treat it as grounding for this sub-task only. Do not cache across sub-task changes — re-fetch when intent changes.

#### 3.10 Acceptance criteria

- [ ] `fetch_skill('mac-keepr', intent: 'make install-copy')` returns `scopedMemory` when mac-scoped memories exist
- [ ] Unknown parent → `global` scope only
- [ ] Empty intent → salience-ranked list within mapped scope(s), limit 5
- [ ] No network beyond existing `fetch_skill` Notion read
- [ ] Hermetic tests with temp `MemoryStore` injected into `SkillsModule` test seam

#### 3.11 Files

- **New:** `TheBridge/Modules/MemoryRoutingScopeMap.swift`
- **New:** `TheBridge/Modules/MemoryRoutingAppendix.swift`
- `TheBridge/Modules/SkillsModule.swift` (wire appendix into handler after skill body resolved)
- `TheBridgeTests/MemoryRoutingAppendixTests.swift` (new)
- `TheBridgeTests/SkillsModuleTests.swift` or dedicated fetch test file
- `TheBridge/Server/ToolAnnotations.swift` (update `fetch_skill` description)

---

### WP3 — Provenance finish + recall shape (D5, D6, D7)

**Goal:** One brain with visible provenance; contradictions survivable.

#### 3.12 Client source threading (verify + complete)

Already implemented for `memory_remember` on SSE + stdio when caller omits `source`.

| Transport | clientName passed | Action |
|-----------|-------------------|--------|
| Streamable HTTP `/mcp` | `SessionContext.clientName` | ✅ verify |
| Legacy SSE | same | ✅ verify |
| stdio | `"stdio"` | ✅ acceptable synthetic label |

**Wave 3:** Include `source` in `memory_recall` JSON response (already on `MemoryEntry`; verify `entryValue` exposes it). Include in `renderMemoryMarkdown` / appendix rows.

#### 3.13 Recall row format (additive)

```markdown
- [fact] Use make install-copy for agent sessions · the-bridge · source: cursor · 2026-06-26 · used 4×
```

#### 3.14 Contradiction policy (documentation only — no new code)

When two live rows share scope+entity but Jaccard < 0.72:
- Both returned at recall
- Agent presents both with provenance
- Resolution = new `memory_remember` (may supersede if near-dup) or `memory_forget` on stale id

#### 3.15 Acceptance criteria

- [ ] `memory_recall` returns `source` field per entry
- [ ] UI Agent tab shows `source` + `createdAt` in meta row
- [ ] Voice-memo writes still show `source: voice-memo`

#### 3.16 Files

- `TheBridge/Modules/MemoryModule.swift` (`entryValue` — verify)
- `TheBridge/Modules/StandingOrders/StandingOrdersDelivery.swift` (`renderMemoryMarkdown`)
- `TheBridge/UI/Sections/MemoryAgentTab.swift`

---

### WP4 — Operator governance UI (D9)

**Goal:** Pin and forget without MCP round-trip; soft-delete only.

#### 3.17 New MCP tool: `memory_pin`

| Field | Value |
|-------|-------|
| Tier | `.notify` |
| Input | `{ "id": "<uuid>", "pinned": true \| false }` |
| Behavior | `MemoryStore.pin(id:pinned:)` |
| Annotation | Required `ToolAnnotationCatalog` entry |

#### 3.18 Agent tab row actions

Per `MemoryAgentTab` row:

| Action | Implementation |
|--------|----------------|
| Pin / Unpin | `memory_pin` via direct `MemoryStore` actor call from UI (same pattern as other Settings panes — no MCP round-trip) |
| Forget | `MemoryStore.forget(id:)` with confirm alert |

**Trust:** No inline text edit. No hard delete.

#### 3.19 Acceptance criteria

- [ ] Pin survives relaunch; pinned rows sort first in recall and inject
- [ ] Forget tombstones row; disappears from list and export
- [ ] Pinned rows never swept by `consolidationSweep`
- [ ] AX IDs: `BridgeAXID.Memory.agentPinButton`, `agentForgetButton`

#### 3.20 Files

- `TheBridge/Modules/MemoryModule.swift` (`memory_pin` registration)
- `TheBridge/UI/Sections/MemoryAgentTab.swift`
- `TheBridge/UI/BridgeAXID.swift` (new identifiers)
- `TheBridge/Server/BridgeModuleRegistry.swift` (+1 tool count)
- `TheBridge/Server/ToolAnnotations.swift`
- `TheBridgeTests/MemoryModuleTests.swift`

---

### WP5 — Lifecycle confirmation (D4) — docs + tests only

**No code change** unless regression found.

| Mechanism | Behavior | Wave 3 |
|-----------|----------|--------|
| Salience decay | Old unused entries rank lower | Keep |
| `ttlSeconds` on remember | Sets `expiresAt`; swept on launch | Keep |
| `reference` 90d unused | Tombstone on `consolidationSweep` | Keep |
| `decision` / `preference` | Indefinite unless TTL or forget | Keep — do not add default TTL |
| Hard delete | Never | Keep |

**Add:** One doc comment block in `MemoryStore.consolidationSweep` cross-linking this spec.

---

### WP6 — Deferred registry (explicit)

| Item | Defer to | Notes |
|------|----------|-------|
| Cloud sync | PKT-MEM-12x | Privacy review required |
| Encryption at rest | Same | Keychain envelope TBD |
| Operator memory authoring (CRUD) | After Wave 3 usage | |
| Demote tiers (hot/warm/cold) | Same | |
| Jobs-based idle consolidation | Same | Launch sweep sufficient for now |
| Claude Code `MEMORY.md` unification | PKT-MEM-966 area | See `v3.7.7-memory-design-questions.md` §6 |
| Notion MEMORY DS sync | Notion-keeper scope | Agent memory stays local |

---

## 4. Implementation phasing

```text
Phase A (ship together) — ~1 PR
  WP1 Auto-inject UI + Cursor seed default
  WP4 memory_pin + Agent tab pin/forget
  WP3 provenance in recall/UI (small)

Phase B — ~1 PR (can parallel after A starts)
  WP2 Memory-rides-routing on fetch_skill
  dispatchContract + tool description update

Phase C — verification only
  WP5 lifecycle audit
  Live handshake smoke (Cursor ON → see ## Memory)
  Live fetch_skill smoke (mac-keepr + mac memories)
```

**Recommended merge order:** A → B. Phase A is operator-facing and low risk; Phase B touches hot `fetch_skill` path.

---

## 5. Test plan + floor

| Test file | New cases (estimate) |
|-----------|---------------------|
| `MemoryModuleTests.swift` | `memory_pin` round-trip; recall includes `source` |
| `MemoryRoutingAppendixTests.swift` | scope map; entity extract; appendix limit; empty omit |
| `StandingOrdersDeliveryTests.swift` | inject toggle + Cursor override composition |
| `MemoryModuleTests.swift` (UI store) | `MemoryAutoInjectClientStore` seed cursor — may exist |

**Floor raise:** +8–12 net-new tests → update `scripts/test-floor-gate.sh` with dated provenance comment only after `make test` green count measured.

**Live verification checklist:**
1. Settings → Memory → Agent: toggle global inject OFF, Cursor ON
2. Restart Bridge; reconnect Cursor → handshake contains `## Memory` with pinned + salient rows
3. `fetch_skill('mac-keepr', intent: 'install copy')` → `scopedMemory.markdown` present
4. Pin a memory in UI → appears first in inject slice
5. Forget a memory → gone from recall and Agent tab

---

## 6. MCP tool inventory delta

| Tool | Tier | Wave 3 |
|------|------|--------|
| `memory_remember` | notify | unchanged |
| `memory_recall` | open | response documents `source` |
| `memory_forget` | notify | unchanged |
| `memory_export` | request | unchanged |
| `memory_import` | request | unchanged |
| `memory_pin` | notify | **NEW** |

`staticFeatureModuleToolCount` +1 when `memory_pin` ships.

---

## 7. Operator setup script (post-Phase A)

After install, Wave 3 seeds:

```text
memoryHandshakeAutoInject = false
memoryAutoInjectClientOverrides = { "cursor": true }
```

Operator may enable global inject from Settings if they later want all clients to receive memory.

---

## 8. Examples — end-to-end flows

### 8.1 Cursor session with inject ON

1. Bridge starts → `consolidationSweep` (silent)
2. Cursor MCP initialize → standing orders + routing index + `## Memory` (top 5 salient)
3. User: "install the bridge build"
4. Agent: `fetch_skill('mac-keepr', intent: 'install bridge build')`
5. Response includes skill body + `scopedMemory` with `make install-copy` fact
6. Agent executes without separate `memory_recall`

### 8.2 Capturing a preference

1. Agent concludes: operator prefers terse answers when tired
2. `memory_remember { text, scope: "global", type: "preference" }` — `source` auto = `cursor`
3. Row appears in Settings → Memory → Agent
4. Next Cursor session: inject surfaces preference if salient enough

### 8.3 Pruning a stale reference

1. 90 days pass without recall on `type: reference` row
2. App launch → `consolidationSweep` tombstones it
3. Row gone from recall/export; still in SQLite for forensics

---

## 9. Risks + mitigations

| Risk | Mitigation |
|------|------------|
| Handshake token bloat | Global OFF; 500-token cap; salience truncation |
| `fetch_skill` latency | Appendix uses local SQLite only; limit 5 entries |
| Wrong scoped memories | Keeper→scope map is conservative; empty appendix when no hits |
| Pin/forget accidents | Confirm on forget; notify tier on `memory_pin` MCP (UI bypasses gate) |
| Tool count inflation | One new tool (`memory_pin`); appendix is not a tool |

---

## 10. Packet breakdown (for PACKETS DS)

| Packet | Scope | Phase |
|--------|-------|-------|
| **PKT-MEM-115a** | WP1 + WP4 + WP3 recall/UI provenance | A |
| **PKT-MEM-115b** | WP2 fetch_skill scopedMemory | B |
| **PKT-MEM-115c** | Live verification + floor raise + CHANGELOG | C |

---

## 11. CHANGELOG entry (draft)

```markdown
## v3.9.0 — Unified Memory Wave 3 (surfacing + governance)

- **Handshake memory inject** — Settings toggle (global OFF default); per-client overrides with Cursor seeded ON.
- **Memory-rides-routing** — `fetch_skill` returns optional `scopedMemory` appendix (keeper→scope map + intent recall).
- **`memory_pin`** — MCP tool + Agent tab pin/forget actions.
- **Provenance** — `memory_recall` and inject surfaces show `source` + date.
- Lifecycle unchanged: `reference` 90d sweep + explicit TTL only.
```

---

*End of spec. Operator approval recorded 2026-06-26. Implementation may proceed on PKT-MEM-115a.*
