# Registry Hydration Design — `packet-registry-v1`

**Lane E (DESIGN ONLY — no code edits, no build).** Maps the existing Bridge
registry read/possess path onto the PRD's `packet-registry-v1` envelope (FR-1,
§8.3) and lists the minimal Swift change set + tests to emit it.

- **Governing spec:** `packet-runner/_refs/PRD-v1.0.md` — FR-1 (§ line 138-139),
  §8.3 (line 245-267), PACKETS relation property names §8.1 (line 197-208).
  The PRD governs where it conflicts with skills/source-packet (Program Plan,
  PRD §14.1).
- **Source read:** `TheBridge/Modules/Registry/` —
  `RegistryReader.swift`, `RegistryModule.swift`, `RegistryWriter.swift`,
  `RegistryModels.swift`, `RegistryGateway.swift`, `RegistrySchema.swift`,
  `RegistryRowCacheModels.swift`, `RegistryPropertyCodec.swift`.
- **Tests read:** `TheBridgeTests/Registry*.swift`, `SpecialistRelationTests.swift`.

---

## 1. How the current registry read/possess path works

### 1.1 Types (all `Sendable` value types)

| Type | File | Role |
|---|---|---|
| `RegistryEntity` | `RegistryModels.swift:98` | `entity → dataSourceId + workspace? + [RegistryProperty] + cacheTTLSeconds + hasBody`. Bound by **property id**. |
| `RegistryProperty` | `RegistryModels.swift:36` | `{key, notionName, notionPropertyId?, type, role}`. `role ∈ {title,status,date,relation,generic}`. `isBound` ⇔ `notionPropertyId` non-empty. |
| `RegistryConfig` | `RegistryModels.swift:191` | `{schemaVersion:Int, entities:[RegistryEntity]}`. Seed = Skills only (`defaultSeed()`, line 243). **No PACKETS entity is seeded** — it must be added via `registry_add_entity` + `registry_introspect`. |
| `NotionRow` | `RegistrySchema.swift:49` | Decoded page: `{id, url, lastEditedTime, cells:[name:NotionCell], archived}`. `cell(for:)` matches by bound id first (rename-safe), then by name. |
| `NotionCell` | `RegistrySchema.swift:37` | `{id, type, value:Value}`. A `relation` cell decodes (via `RegistryPropertyCodec.decode`, `RegistryPropertyCodec.swift:94`) to `.array([.string(relatedPageId), …])` — **bare related ids, no title/status**. |
| `DataSourceSchema` | `RegistrySchema.swift:17` | `columnsByName:[name:{id,type}]` from `getDataSource`; drives binding + drift. |
| `CachedRow` | `RegistryRowCacheModels.swift:31` | On-disk projection: `{entity, pageId(normalized), title, url, properties:Value, lastEditedTime, writtenAt, ttlSeconds, callCount}`. `isExpired(now:)` is the staleness clock. |
| `RegistryNotionGateway` | `RegistryGateway.swift:17` | Protocol: `schema / query / page / create / update / archive / markdown`. `LiveRegistryGateway` resolves the per-workspace `NotionClient` and throttles every call through `RegistryRateLimiter` (2 req/s). |

### 1.2 Read functions

- **`RegistryReader.get(entity:pageId:forceRefresh:)`** (`RegistryReader.swift:73`)
  — cache-first single row. Fresh cache hit → serve + tick `callCount`; stale →
  live `fetchAndStore`, **serve the stale copy on failure** (offline); miss →
  `fetchAndStore`. `fetchAndStore` (line 92) treats an `archived`/empty-id page as
  not-found (evict + throw `RegistryReadError.deleted`).
- **`RegistryReader.list(entity:limit:)`** (`RegistryReader.swift:113`) — paginates
  `query` (100/req, `next_cursor`, 200-page backstop), caches each projection;
  on network failure serves the on-disk cache, rethrows only if nothing cached.
- **`RegistryReader.body(entity:pageId:)`** (`RegistryReader.swift:144`) — the
  `possess`/`fetch_skill` verb. Returns `gateway.markdown(...)` (page body markdown)
  **only when `entity.hasBody`**; not cached on this path (bodies load on demand,
  Decision 4).
- **Projection — `RegistryReader.project(_:entity:)`** (`RegistryReader.swift:39`):
  the existing relation projection. For each `entity.property`, looks up the
  matching cell by bound id and writes `out[prop.key] = cell.value`. So a relation
  property surfaces under its **canonical key** (e.g. `skills`) as a **bare id
  array** — there is **no title/status enrichment and no second hop today**.

### 1.3 Tool surface (`RegistryModule.swift`)

`registry_get` (line 285) → `reader.get` → `rowValue(...)` (line 86):
`{entity,id,title,url,lastEditedTime,stale,properties}`. `registry_possess`
(line 393) → `reader.body`. `registry_list` (line 253). All flow through the
injectable `gatewayProvider` seam (line 30) — tests swap an actor fake; production
uses `LiveRegistryGateway`.

**Gap vs. §8.3:** the current `get`/`rowValue` shape is **flat** (one row's
projected properties, relations as bare id arrays). It has **no** `schemaVersion`
discriminator, no `primary`/`body`/`relations`/`provenance`/`warnings` separation,
and **no relation enrichment** (`{id,title,status}` per related page). Emitting
`packet-registry-v1` is therefore an **additive new path**, not a reshape of
`registry_get`.

### 1.4 The other relation projection (NOT this path)

`NotionJSON.extractSpecialistRelationIDs` (`SpecialistRelationTests.swift`) is the
**routing-layer** Skills specialist resolver — a separate subsystem that walks a
`Specialist` relation → ids → `getPage` → `CachedSpecialist`. It is the closest
existing precedent for "relation id → one-hop hydrate" but lives outside the
registry and returns specialists, not the generic `{id,title,status}` projection.
The new code must implement its **own** registry-native one-hop projector; reuse
the *pattern* (extract ids, fetch each once, filter), not that function.

---

## 2. The exact `packet-registry-v1` envelope (§8.3, verbatim shape)

```json
{
  "schemaVersion": "packet-registry-v1",
  "primary": {
    "id": "packet-page-id",
    "title": "...",
    "lastEditedTime": "ISO-8601",
    "properties": { "status": "QUEUE", "executionClass": "AUTO", "...": "..." }
  },
  "body": "full packet markdown",
  "relations": {
    "project":   [{ "id": "...", "title": "...", "status": "..." }],
    "skills":    [{ "id": "...", "name": "...", "version": "...", "status": "..." }],
    "blockedBy": [{ "id": "...", "title": "...", "status": "DONE" }],
    "blocking":  [],
    "event":     []
  },
  "provenance": { "fetchedAt": "ISO-8601", "source": "notion" },
  "warnings": []
}
```

**Binding rules (§8.3 line 267 + FR-1 line 139):**
- `schemaVersion` is the literal string `"packet-registry-v1"` (NOT the numeric
  `RegistryConfig.schemaVersion`). It is the envelope discriminator the dispatch
  (`registrySchemaVersion`, §8.4 line 277) and executor revalidation (FR-6) match on.
- `primary.properties` = the existing flat projection (`CachedRow.properties`),
  **minus** the five relation properties (those move into `relations`). Keys are
  the entity's canonical keys (e.g. `status`, `executionClass`).
- `body` = full packet markdown (the `possess` path output). Loaded for the
  **primary only**.
- `relations` — the **five PACKETS relations** by §8.1 (line 202-208), mapped to
  these fixed envelope keys:
  | Envelope key | PACKETS Notion property (§8.1) | Per-item shape |
  |---|---|---|
  | `project`   | `PROJECT`    | `{id,title,status}` |
  | `skills`    | `SKILLS`     | `{id,name,version,status}` |
  | `blockedBy` | `Blocked by` | `{id,title,status}` |
  | `blocking`  | `Blocking`   | `{id,title,status}` |
  | `event`     | `EVENT`      | `{id,title,status}` (PRD gives no item fields; default to title/status; empty arrays are valid) |
- **One hop only** — each related page is fetched **once** for its props
  (`title`/`name`, `status`, `version`); its own relations and its **body are NOT
  fetched** (§8.3: "Hydration stops after one relation hop. Relation bodies are
  omitted.").
- `provenance.fetchedAt` = ISO-8601 of the fetch; `source` = `"notion"`.
- `warnings` — one human-readable string per **missing or inaccessible** relation
  target (§8.3: "Unknown or inaccessible relations produce warnings rather than
  guessed values"; FR-1). A related id that 404s / errors / is archived ⇒ it is
  **omitted from the projection** and a warning is appended — never a guessed/empty
  stand-in row.

---

## 3. Mapping: what exists vs. what must be ADDED

| §8.3 element | Exists today? | What must be added/changed |
|---|---|---|
| `schemaVersion:"packet-registry-v1"` | ✗ | New constant; emitted by the new hydrate path. |
| `primary.{id,title,lastEditedTime}` | ✓ (`CachedRow`) | Reuse `CachedRow.pageId/title/lastEditedTime` (carry the original dashed id for downstream — see §3.1). |
| `primary.properties` (relations excluded) | partial (flat projection includes relations as id arrays) | **Split**: project non-relation props into `primary.properties`; route `role == .relation` props to `relations`. |
| `body` | ✓ (`reader.body`) | Reuse for the primary; gate on `hasBody` (a packet body is authored markdown → `hasBody == true` on the PACKETS entity). |
| `relations.{project,skills,blockedBy,blocking,event}` as `{id,title,status,…}` | ✗ (only bare ids) | **New one-hop projector**: for each relation property, take the bare id array, fetch each target once via `gateway.page`, project `title`/`name`/`status`/`version`, map to the fixed envelope key. |
| one-hop-only / no relation bodies | ✗ (no hop at all) | New projector fetches props only — never `markdown`, never a second relation hop. |
| `provenance.{fetchedAt,source}` | ✗ | New: stamp `fetchedAt = Date()` ISO-8601, `source = "notion"`. |
| `warnings[]` for missing/inaccessible | ✗ | New: accumulate a warning per relation target that 404s/errors/is archived; omit that item. |
| cache reuse + stale-while-revalidate | ✓ (`get`) | Primary fetch goes through `reader.get` (warm-cache, offline-tolerant). Relation targets: fetch via `gateway.page` directly (one hop, not cached as projected rows of *this* entity — they belong to other entities). |
| explicit deeper body fetch | ✓ (`registry_possess`) | Unchanged. The hydrate envelope omits relation bodies; a caller wanting a related body calls `registry_possess` on that id explicitly (FR-1 "Deeper reads are explicit."). |

### 3.1 Decisions / notes (cite)

- **D-A — additive tool, not a reshape.** Add a new `registry_hydrate` tool +
  `RegistryReader.hydrate(...)`; leave `registry_get`/`rowValue` untouched.
  Rationale: §8.3's nested envelope is a different contract from the flat
  `registry_get`; existing callers + `RegistryModuleTests` must not break; FR-1
  demands the separated shape only for the packet fetch. (PRD FR-1, §8.3.)
- **D-B — relation property identification is role-driven + key-mapped.** The
  projector selects `entity.properties` where `role == .relation`
  (`RegistryModels.swift:281` already sets `.relation` for relation props) and maps
  each property's **canonical key** to the fixed envelope key via a small table
  (`project/skills/blockedBy/blocking/event`). The PACKETS entity's property map
  must therefore declare those five with canonical keys matching the table and
  `role:relation`. **BLOCKED: operator must register the PACKETS entity** (no
  hardcoded data-source ids — Decision 5; PRD §8.5A lists `project_id`/page ids as
  operator-supplied). The PACKETS data source id is `078e7c9e-e53e-4c83-a893-af64f82b5123`
  (`_refs/SCHEMA_GAP.md`), but the *entity registration* (canonical-key→property
  map + introspect to bind ids) is a deploy-time step, not a code constant.
- **D-C — id form.** `CachedRow.pageId` is normalized (dashless, lowercased,
  `RegistryRowCacheModels.swift:126`). The relation cell ids from the codec are the
  **dashed** Notion ids (`RegistryPropertyCodec.swift:96`). For one-hop fetches pass
  the ids **as returned** (`gateway.page`/`getPage` accepts dashed). For
  `primary.id` in the envelope, prefer the **original `NotionRow.id`** (dashed) over
  the normalized cache id so downstream dispatch (§8.4 `packetId`) carries the
  canonical page id. This means `hydrate` needs access to the **live `NotionRow`**,
  not only the `CachedRow` (see §4 — `getRow` helper).
- **D-D — status string.** A `status` cell decodes to `.string("QUEUE")` etc. via
  the codec; relation targets' `status` is read the same way from each target's
  `NotionRow`. The projector reads it through a target **entity property map when
  one exists**, else falls back to a fixed Notion property name (`"Status"`) —
  because a related PROJECT/EVENT page may belong to an entity that is **not
  registered**, in which case there is no canonical map to project through.
  **Failing closed:** if `status` cannot be resolved, emit the item with `status`
  omitted (NOT guessed) and, when the whole target is unreadable, drop it + warn
  (§8.3, FR-4 "missing or inaccessible relation … rather than guessing").
- **D-E — no central PACKETS-specific logic in the generic core.** Keep the
  relation-key table + per-item field selection (`title` vs `name`, `version` for
  skills) data-driven so the generic CRUD ethos holds (CLAUDE.md: "generic CRUD
  tools, not per-entity"). The table is the only packet-shaped knowledge and is
  small + documented.

---

## 4. Minimal Swift change list (no code written)

**New file — `TheBridge/Modules/Registry/RegistryHydration.swift`**
- `public struct PacketRegistryEnvelope: Sendable` — typed mirror of §8.3:
  `schemaVersion:String`, `primary:Primary`, `body:String`,
  `relations:[String:[Value]]` (or a typed `Relations` struct with the 5 fixed
  keys), `provenance:Provenance`, `warnings:[String]`. Nested
  `Primary{id,title,lastEditedTime,properties:Value}`,
  `Provenance{fetchedAt:String, source:String}`. Has `func asValue() -> Value` so
  the module returns it directly as the MCP result.
- `public struct RelationProjection: Sendable` (or a static enum) — the
  canonical-key → envelope-key table (`project/skills/blockedBy/blocking/event`)
  and per-key item-field rules (which cell keys to read: title/name/status/version).
- `static let packetRegistrySchemaVersion = "packet-registry-v1"`.

**Change — `RegistryReader.swift`**
- Add `public func getRow(entity:pageId:forceRefresh:) async throws -> NotionRow`
  (or refactor `fetchAndStore` to also surface the live `NotionRow`) so `hydrate`
  has the primary's **live row** (dashed id + raw relation cells), not just the
  projected `CachedRow`. Reuse the existing cache/offline semantics.
- Add `public func hydrate(entity:pageId:forceRefresh:) async throws ->
  PacketRegistryEnvelope`:
  1. fetch primary row (`getRow`), project non-relation props → `primary.properties`;
     load `body` via existing `body(entity:pageId:)` when `entity.hasBody`.
  2. for each `role == .relation` property: read its bare id array from the primary
     row's cell; for each id, `gateway.page(pageId:workspace:)` **once**; on
     success project `{id,title|name,status,version?}`; on `archived`/error/empty →
     skip + append a warning. Map under the envelope key from the table.
  3. stamp `provenance` (`fetchedAt = now`, `source = "notion"`); attach `warnings`.
- Add a small `static func projectRelationTarget(_ row:NotionRow, key:String) ->
  Value` helper (title/name/status/version selection by envelope key).
- Reuse `RegistryReader.RegistryReadError` for the per-target deleted/archived case
  (caught internally → warning, not propagated).

**Change — `RegistryModule.swift`**
- `makeHydrate() -> ToolRegistration` named `registry_hydrate`, tier `.open`
  (read-only), input `{entity, id, forceRefresh?}`. Handler resolves the entity
  (`requireEntity`), builds `RegistryReader(gateway: gateway())`, calls
  `hydrate(...)`, returns `envelope.asValue()`.
- Register it in `register(on:)` (line 100). **Tool-count + annotation invariant:**
  bump `staticFeature ModuleToolCount` and add a `ToolAnnotationCatalog` entry
  (CLAUDE.md: every live tool needs one or `ToolAnnotationAuditTests` hard-fails).

**No change needed** to `RegistryGateway` (the `page`/`markdown` calls already
exist), `RegistryPropertyCodec` (relation already decodes to id arrays),
`RegistryWriter`, or `RegistryModels` (the `.relation` role already exists). The
PACKETS **entity registration** is operator/runtime data, not source.

---

## 5. Test list to add (deterministic, hermetic — matches the existing
`actor`-fake-gateway pattern in `RegistryModuleTests.swift` / `RegistryEdgeCaseTests.swift`)

New file `TheBridgeTests/RegistryHydrationTests.swift` with an `actor`
`HydrationFakeGateway: RegistryNotionGateway` exposing injectable `pages:[id:
NotionRow]`, a per-id `inaccessible:Set<String>` (throws), and a `failNetwork`
flag — mirroring `ModFakeGateway`/`EdgeGateway`. Required cases (PRD §10.4
checklist, line 919: "missing relations, inaccessible relations, stale cache
refresh, no recursive hydration, explicit deeper body fetch"):

1. **Envelope shape** — happy path: a PACKET with one `PROJECT`, two `SKILLS`, one
   `Blocked by` produces `schemaVersion=="packet-registry-v1"`, populated
   `primary{id,title,lastEditedTime,properties}` (relations excluded from
   `properties`), `body`, the five `relations` keys present (empty arrays for
   `blocking`/`event`), `provenance.source=="notion"` + parseable `fetchedAt`,
   `warnings==[]`. Assert per-item fields (`project`→title+status; `skills`→
   name+version+status).
2. **Missing relation** — a relation id with no page in the fake ⇒ that item is
   **omitted** and exactly one `warnings[]` entry names the missing id; the rest of
   the projection is intact (FR-4, §8.3).
3. **Inaccessible relation** — a relation id that **throws** (in `inaccessible`) or
   resolves to an `archived` row ⇒ omitted + warned; no guessed/empty stand-in row
   (§8.3 "rather than guessed values").
4. **Stale cache refresh** — primary in cache but expired ⇒ `hydrate` revalidates
   (live row used); on a `failNetwork` refresh failure it serves the **stale cached
   primary** and still emits a valid envelope (reuses `get` offline semantics,
   `RegistryReader.swift:85`). Assert primary fields come from the stale copy.
5. **No recursive hydration** — a related target whose own `NotionRow` itself
   carries relation cells does **NOT** trigger further fetches: assert the fake
   gateway's `page` call count equals `1 (primary) + N (distinct relation ids)` and
   that no related item contains nested `relations`/`body`. Guards §8.3 "stops after
   one relation hop" + "relation bodies are omitted".
6. **Explicit deeper body fetch** — `hydrate` does NOT populate any relation
   `body`; a follow-up `registry_possess` on a related id returns that body (the
   only way to get it). Asserts FR-1 "Deeper reads are explicit."
7. **(supporting) Primary-only body gate** — `hasBody==false` entity ⇒ `body==""`
   and no `markdown` call (reuses `body(...)` gate, `RegistryReader.swift:145`).
8. **(supporting) dedup** — a relation listing the same id twice fetches it once
   (matches the specialist-relation dedup precedent, `SpecialistRelationTests` case 4).

### Test-floor convention (`scripts/test-floor-gate.sh`)

The harness fails CI if the green count drops below `FLOOR` **or** any test fails.
After adding the above, the implementer must: run the suite, count the new green
total, **raise `FLOOR=`** (currently `FLOOR="${BRIDGE_TEST_FLOOR:-2242}"`, line 1415
— the authoritative value; CLAUDE.md's "2169" and MEMORY's "2163/2030" are stale),
and add a **dated provenance comment** in the existing style, e.g.
`# vX.Y (2026-06-23): +8 RegistryHydrationTests (packet-registry-v1 envelope:
missing/inaccessible relations, one-hop guard, stale-cache, deeper-body) (2242→NNNN).`
Never lower the floor without a recorded reason. Also: new tool ⇒ bump
`staticFeature ModuleToolCount` + add the `ToolAnnotationCatalog` entry, or
`ToolAnnotationAuditTests` / `BridgeModuleRegistryTests` hard-fail.

---

## BLOCKED / open items

- **BLOCKED: operator must register the PACKETS entity at deploy time** —
  `registry_add_entity` (canonical keys `status, executionClass, project, skills,
  blockedBy, blocking, event, …` with `role:relation` on the five relations, mapped
  to the envelope table in §3 D-B) against data source
  `078e7c9e-e53e-4c83-a893-af64f82b5123`, then `registry_introspect` to bind property
  ids. No hardcoded data-source id ships in the seed (Decision 5; PRD §8.5A
  operator-supplied page ids). The Swift hydrate path is entity-agnostic and works
  once any entity with those role/key mappings is registered.
- **Open (PRD-silent): `event` item fields.** §8.3 shows `event: []` with no item
  schema. Design defaults EVENT items to `{id,title,status}` (same as
  project/blockedBy). If the PACKETS EVENT relation should project different fields,
  that is a spec clarification, not a code blocker — the table in
  `RegistryHydration.swift` is the single place to adjust.
- **Open: related-target status source.** When a related page belongs to an
  **unregistered** entity, status is read by the fixed Notion name `"Status"`
  (D-D). If a target uses a differently-named status column, status is omitted (fail
  closed, never guessed). Registering that target's entity makes it project through
  the canonical map instead.
