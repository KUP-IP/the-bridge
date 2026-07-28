import Foundation
import MCP
import TheBridgeLib

private func packetProperty(_ field: PacketRegistryContract.Field, bound: Bool = true) -> RegistryProperty {
    let role: RegistryPropertyRole
    switch field.type {
    case "title": role = .title
    case "status": role = .status
    case "relation": role = .relation
    default: role = .generic
    }
    return RegistryProperty(
        key: field.key,
        notionName: field.notionName,
        notionPropertyId: bound ? "id_\(field.key)" : nil,
        type: field.type,
        role: role)
}

private func packetConfig(
    displayName: String = "Sessions",
    key: String = "session",
    unboundKey: String? = nil
) -> RegistryConfig {
    var properties = PacketRegistryContract.fields.map { packetProperty($0, bound: $0.key != unboundKey) }
    properties.append(RegistryProperty(
        key: "output", notionName: "Packet Output", notionPropertyId: "id_output",
        type: "rich_text"))
    let packet = RegistryEntity(
        key: key, displayName: displayName, dataSourceId: "packets-ds",
        properties: properties, cacheTTLSeconds: 300, hasBody: true)
    let project = RegistryEntity(
        key: "project", displayName: "Projects", dataSourceId: "projects-ds",
        properties: [], cacheTTLSeconds: 300)
    let skill = RegistryEntity(
        key: "skill", displayName: "Skills", dataSourceId: "skills-ds",
        properties: [], cacheTTLSeconds: 300)
    return RegistryConfig(entities: [packet, project, skill])
}

private func packetSchema() -> DataSourceSchema {
    var columns: [String: DataSourceSchema.Column] = [:]
    for field in PacketRegistryContract.fields {
        let relationTarget: String?
        switch field.key {
        case "project": relationTarget = "projects-ds"
        case "skills": relationTarget = "skills-ds"
        case "blockedBy", "blocking": relationTarget = "packets-ds"
        default: relationTarget = nil
        }
        columns[field.notionName] = .init(
            id: "id_\(field.key)", type: field.type,
            options: field.requiredOptions.sorted(), relationDataSourceId: relationTarget)
    }
    return DataSourceSchema(columnsByName: columns)
}

private func defectCodes(_ defects: [PacketRegistryPreflight.Defect]) -> Set<String> {
    Set(defects.map(\.code))
}

private func replacingColumn(
    _ schema: DataSourceSchema,
    named name: String,
    with column: DataSourceSchema.Column?
) -> DataSourceSchema {
    var columns = schema.columnsByName
    columns[name] = column
    return DataSourceSchema(columnsByName: columns)
}

func runPacketRegistryContractTests() async {
    print("\n📦 Packet registry contract")

    await test("Packet identity: live session/Sessions binding aliases to canonical packet") {
        let config = packetConfig()
        try expect(config.entity("packet")?.key == "packet")
        try expect(config.entity("session")?.key == "packet")
        try expect(config.entity("packet")?.dataSourceId == "packets-ds")
        try expect(config.entity("session")?.dataSourceId == "packets-ds")
    }

    await test("Packet identity: genuine Sessions entity is not aliased") {
        let sessions = RegistryEntity(
            key: "session", displayName: "Sessions", dataSourceId: "sessions-ds",
            properties: [RegistryProperty(key: "name", notionName: "Session Name", type: "title")],
            cacheTTLSeconds: 300)
        let config = RegistryConfig(entities: [sessions])
        try expect(config.entity("packet") == nil)
        try expect(config.entity("session")?.key == "session")
        try expect(config.entity("session")?.dataSourceId == "sessions-ds")
    }

    await test("Packet identity: genuine Sessions can coexist with canonical packet") {
        let sessions = RegistryEntity(
            key: "session", displayName: "Sessions", dataSourceId: "sessions-ds",
            properties: [RegistryProperty(key: "name", notionName: "Session Name", type: "title")],
            cacheTTLSeconds: 300)
        var config = packetConfig(displayName: "PACKETS", key: "packet")
        config.entities.insert(sessions, at: 0)
        try expect(config.entity("session")?.key == "session")
        try expect(config.entity("session")?.dataSourceId == "sessions-ds")
        try expect(config.entity("packet")?.key == "packet")
        try expect(config.entity("packet")?.dataSourceId == "packets-ds")
    }

    await test("Packet identity: duplicate canonical and legacy bindings fail preflight") {
        var config = packetConfig()
        let duplicate = PacketRegistryContract.canonicalized(config.entities[0])
        config.entities.append(duplicate)
        try expect(defectCodes(PacketRegistryPreflight.evaluate(config: config, schema: packetSchema())).contains("DUPLICATE_BINDING"))
    }

    await test("Packet identity: fully bound legacy row outranks unbound canonical remnant") {
        let boundLegacy = packetConfig().entities[0]
        let unboundCanonical = RegistryEntity(
            key: "packet", displayName: "PACKETS", dataSourceId: "stale-ds",
            properties: PacketRegistryContract.fields.map { packetProperty($0, bound: false) },
            cacheTTLSeconds: 300, hasBody: true)
        let config = RegistryConfig(entities: [unboundCanonical, boundLegacy] + Array(packetConfig().entities.dropFirst()))
        try expect(config.entity("packet")?.dataSourceId == "packets-ds")
        try expect(config.entity("session")?.dataSourceId == "packets-ds")
        try expect(config.entity("packet")?.isFullyBound == true)
        try expect(defectCodes(PacketRegistryPreflight.evaluate(config: config, schema: packetSchema())).contains("DUPLICATE_BINDING"))
    }

    await test("Packet preflight: complete canonical contract passes") {
        let defects = PacketRegistryPreflight.evaluate(config: packetConfig(), schema: packetSchema())
        try expect(defects.isEmpty, "unexpected defects: \(defects)")
        let result = PacketRegistryPreflight.value(
            contractVersion: PacketRegistryContract.version,
            config: packetConfig(), schema: packetSchema())
        guard case .object(let object) = result else { throw TestError.assertion("not object") }
        try expect(object["result"] == .string("PASS"))
        try expect(object["canonicalEntity"] == .string("packet"))
        try expect(object["defectCount"] == .int(0))
    }

    await test("Packet preflight: missing field is exact") {
        let schema = replacingColumn(packetSchema(), named: "Mission Hash", with: nil)
        let defects = PacketRegistryPreflight.evaluate(config: packetConfig(), schema: schema)
        try expect(defects.contains { $0.code == "MISSING_FIELD" && $0.field == "missionHash" })
    }

    await test("Packet preflight: renamed field is distinguished from missing") {
        var columns = packetSchema().columnsByName
        let objective = columns.removeValue(forKey: "Objective")!
        columns["Mission Objective"] = objective
        let defects = PacketRegistryPreflight.evaluate(
            config: packetConfig(), schema: DataSourceSchema(columnsByName: columns))
        try expect(defects.contains { $0.code == "RENAMED_FIELD" && $0.field == "objective" && $0.actual == "Mission Objective" })
    }

    await test("Packet preflight: type drift is explicit") {
        let schema = replacingColumn(
            packetSchema(), named: "Objective",
            with: .init(id: "id_objective", type: "title"))
        let defects = PacketRegistryPreflight.evaluate(config: packetConfig(), schema: schema)
        try expect(defects.contains { $0.code == "TYPE_MISMATCH" && $0.field == "objective" })
    }

    await test("Packet preflight: required status option drift is explicit") {
        let schema = replacingColumn(
            packetSchema(), named: "Status",
            with: .init(
                id: "id_status", type: "status",
                options: ["Backlog", "QUEUE", "REVIEW", "BLOCKED", "FOCUS", "Done"]))
        let defects = PacketRegistryPreflight.evaluate(config: packetConfig(), schema: schema)
        try expect(defects.contains { $0.code == "REQUIRED_OPTION_MISMATCH" && $0.field == "status" })
    }

    await test("Packet preflight: relation target drift is explicit") {
        let schema = replacingColumn(
            packetSchema(), named: "PROJECT",
            with: .init(id: "id_project", type: "relation", relationDataSourceId: "wrong-ds"))
        let defects = PacketRegistryPreflight.evaluate(config: packetConfig(), schema: schema)
        try expect(defects.contains { $0.code == "RELATION_TARGET_MISMATCH" && $0.field == "project" })
    }

    await test("Packet preflight: stale binding id is explicit") {
        var config = packetConfig()
        var packet = config.entities[0]
        var properties = packet.properties
        let index = properties.firstIndex { $0.key == "objective" }!
        properties[index].notionPropertyId = "stale-id"
        packet.properties = properties
        config.entities[0] = packet
        let defects = PacketRegistryPreflight.evaluate(config: config, schema: packetSchema())
        try expect(defects.contains { $0.code == "BINDING_MISMATCH" && $0.field == "objective" })
    }

    await test("Packet preflight: unbound additive field is explicit") {
        let defects = PacketRegistryPreflight.evaluate(
            config: packetConfig(unboundKey: "missionHash"), schema: packetSchema())
        try expect(defects.contains { $0.code == "UNBOUND_FIELD" && $0.field == "missionHash" })
    }

    await test("Packet preflight: duplicate canonical field bindings fail closed") {
        var config = packetConfig()
        var packet = config.entities[0]
        packet.properties.append(RegistryProperty(
            key: "missionHash", notionName: "Legacy Mission Hash",
            notionPropertyId: "stale-mission-hash", type: "rich_text"))
        config.entities[0] = packet
        let defects = PacketRegistryPreflight.evaluate(config: config, schema: packetSchema())
        try expect(defects.contains {
            $0.code == "DUPLICATE_FIELD_BINDING" && $0.field == "missionHash" && $0.actual == "2"
        })
    }

    await test("Packet projection: duplicate canonical keys use the same first-binding precedence") {
        let first = RegistryProperty(
            key: "missionHash", notionName: "Mission Hash",
            notionPropertyId: "first", type: "rich_text")
        let second = RegistryProperty(
            key: "missionHash", notionName: "Legacy Mission Hash",
            notionPropertyId: "second", type: "rich_text")
        let entity = RegistryEntity(
            key: "packet", displayName: "PACKETS", dataSourceId: "packets-ds",
            properties: [first, second], cacheTTLSeconds: 300)
        let row = NotionRow(
            id: "id", url: "u", lastEditedTime: "t",
            cells: [
                "Mission Hash": NotionCell(id: "first", type: "rich_text", value: .string("first-value")),
                "Legacy Mission Hash": NotionCell(id: "second", type: "rich_text", value: .string("second-value")),
            ])
        let projected = RegistryReader.project(row, entity: entity).properties
        guard case .object(let properties) = projected else { throw TestError.assertion("not object") }
        try expect(properties["missionHash"] == .string("first-value"))
    }

    await test("Packet preflight: unsupported contract version fails closed") {
        let result = PacketRegistryPreflight.value(
            contractVersion: "packet-registry-v2", config: packetConfig(), schema: packetSchema())
        guard case .object(let object) = result else { throw TestError.assertion("not object") }
        try expect(object["result"] == .string("DRIFT"))
        try expect(object["defectCount"] == .int(1))
    }

    await test("Packet schema decoder retains status options and relation targets") {
        let raw: [String: Any] = ["properties": [
            "Status": ["id": "status-id", "type": "status", "status": ["options": [["name": "QUEUE"], ["name": "Done"]]]],
            "PROJECT": ["id": "project-id", "type": "relation", "relation": ["data_source_id": "projects-ds"]],
        ]]
        let schema = RegistryRowDecoder.schema(from: raw)
        try expect(schema.column(named: "Status")?.options == ["Done", "QUEUE"])
        try expect(schema.column(named: "PROJECT")?.relationDataSourceId == "projects-ds")
        try expect(schema.column(withID: "project-id")?.name == "PROJECT")
    }

    await test("Packet mission: heading levels, checkboxes, and managed-output boundary normalize") {
        let body = "  ##   Objective  \r\n- [X] ship   \r\n\r\n   ## Packet Runner Output   \r\nmanaged"
        let authored = PacketMissionIntegrity.authoredBody(body)
        try expect(authored == "## Objective\n- [x] ship", "authored=\(authored)")
    }

    await test("Packet mission: managed-output heading inside a code fence is authored content") {
        let body = [
            "## Scope",
            "```md",
            "## Packet Runner Output",
            "- [X] example" + "  ",
            "```",
            "After fence",
            "## Packet Runner Output",
            "managed",
        ].joined(separator: "\n")
        let authored = PacketMissionIntegrity.authoredBody(body)
        try expect(authored.contains("## Packet Runner Output\n- [X] example  "), "fenced example preserved")
        try expect(authored.contains("After fence"), "content after fenced example preserved")
        try expect(!authored.contains("managed"), "real managed-output section excluded")
    }

    await test("Packet mission: code-fence whitespace and checkbox case remain material") {
        let properties = ["title": "T", "objective": "O", "sourceOfTruth": "S", "executionClass": "AUTO"]
        let a = PacketMissionIntegrity.canonical(
            title: "P", properties: properties, relations: [:],
            body: "```\n- [X] code  \n\n```")
        let b = PacketMissionIntegrity.canonical(
            title: "P", properties: properties, relations: [:],
            body: "```\n- [x] code\n```")
        try expect(PacketMissionIntegrity.hash(canonical: a) != PacketMissionIntegrity.hash(canonical: b))
    }

    await test("Packet mission: duplicate-field headings inside code fences are ignored") {
        let properties = ["objective": "Ship safely"]
        let body = "```md\n## Objective\nContradiction\n```\n## Scope\nReal mission"
        try expect(PacketMissionIntegrity.conflictFields(properties: properties, body: body).isEmpty)
    }

    await test("Packet mission: formatting and managed output are hash-stable") {
        let properties = ["title": "Canonical", "objective": "Ship", "sourceOfTruth": "A1", "executionClass": "AUTO"]
        let a = PacketMissionIntegrity.canonical(
            title: "P", properties: properties, relations: [:],
            body: "#  Goal\r\n- [X] one   \n\n\n## Packet Runner Output\nmanaged")
        let b = PacketMissionIntegrity.canonical(
            title: "P", properties: properties, relations: [:],
            body: "# Goal\n- [x] one\n")
        try expect(PacketMissionIntegrity.hash(canonical: a) == PacketMissionIntegrity.hash(canonical: b))
    }

    await test("Packet mission: packet title and authored mission edits change hash") {
        let base = ["title": "Title A", "objective": "Ship", "sourceOfTruth": "A1", "executionClass": "AUTO"]
        let one = PacketMissionIntegrity.canonical(title: "PKT-A", properties: base, relations: [:], body: "## Scope\nOne")
        var titleChanged = base
        titleChanged["title"] = "Title B"
        let two = PacketMissionIntegrity.canonical(title: "PKT-A", properties: titleChanged, relations: [:], body: "## Scope\nOne")
        let three = PacketMissionIntegrity.canonical(title: "PKT-A", properties: base, relations: [:], body: "## Scope\nTwo")
        try expect(PacketMissionIntegrity.hash(canonical: one) != PacketMissionIntegrity.hash(canonical: two))
        try expect(PacketMissionIntegrity.hash(canonical: one) != PacketMissionIntegrity.hash(canonical: three))
    }

    await test("Packet mission: relation ordering and UUID dash form are stable") {
        let properties = ["title": "T", "objective": "O", "sourceOfTruth": "S", "executionClass": "AUTO"]
        let a = PacketMissionIntegrity.canonical(
            title: "P", properties: properties,
            relations: ["skills": ["AAAA-BBBB", "CCCC-DDDD"]], body: "")
        let b = PacketMissionIntegrity.canonical(
            title: "P", properties: properties,
            relations: ["skills": ["ccccdddd", "aaaabbbb", "aaaabbbb"]], body: "")
        try expect(a == b)
    }

    await test("Packet mission: revision preparation is new, stable, then incremental") {
        let canonicalA = PacketMissionIntegrity.canonical(title: "P", properties: [:], relations: [:], body: "A")
        let first = try PacketMissionIntegrity.prepare(storedRevision: nil, storedHash: nil, canonical: canonicalA)
        try expect(first.revision == 1 && first.changed && !first.hash.isEmpty)
        let stable = try PacketMissionIntegrity.prepare(storedRevision: 1, storedHash: first.hash, canonical: canonicalA)
        try expect(stable.revision == 1 && !stable.changed && stable.hash == first.hash)
        let canonicalB = PacketMissionIntegrity.canonical(title: "P", properties: [:], relations: [:], body: "B")
        let changed = try PacketMissionIntegrity.prepare(storedRevision: 1, storedHash: first.hash, canonical: canonicalB)
        try expect(changed.revision == 2 && changed.changed && changed.hash != first.hash)
    }

    await test("Packet mission: incomplete stored revision/hash state fails closed") {
        let canonical = PacketMissionIntegrity.canonical(title: "P", properties: [:], relations: [:], body: "A")
        for state in [(1 as Int?, nil as String?), (nil as Int?, "stored" as String?)] {
            var threw = false
            do {
                _ = try PacketMissionIntegrity.prepare(
                    storedRevision: state.0, storedHash: state.1, canonical: canonical)
            } catch PacketMissionIntegrity.PreparationError.incompleteStoredMissionState {
                threw = true
            }
            try expect(threw, "incomplete stored state must throw")
        }
    }

    await test("Packet mission: explicit duplicated body fields detect contradiction") {
        let properties = ["title": "T", "objective": "Ship safely", "sourceOfTruth": "A1", "executionClass": "REVIEW-FIRST"]
        let consistentBody = "## Objective\nShip safely\n## Execution Class\nREVIEW-FIRST. Review required."
        try expect(PacketMissionIntegrity.conflictFields(properties: properties, body: consistentBody).isEmpty)
        let conflictBody = "## Objective\nShip quickly\n## Execution Class\nAUTO"
        try expect(Set(PacketMissionIntegrity.conflictFields(properties: properties, body: conflictBody)) == Set(["objective", "executionClass"]))
    }

    await test("Packet mission: all four consistency classifications are reachable") {
        let properties = ["objective": "Ship", "executionClass": "AUTO"]
        let body = "## Objective\nShip\n## Execution Class\nAUTO"
        let canonical = PacketMissionIntegrity.canonical(title: "P", properties: properties, relations: [:], body: body)
        let hash = PacketMissionIntegrity.hash(canonical: canonical)
        try expect(PacketMissionIntegrity.classify(
            storedRevision: nil, storedHash: nil, canonical: canonical,
            properties: properties, body: body) == .MISSING_REVISION)
        try expect(PacketMissionIntegrity.classify(
            storedRevision: 1, storedHash: hash, canonical: canonical,
            properties: properties, body: "## Objective\nContradiction") == .PROPERTY_BODY_CONFLICT)
        try expect(PacketMissionIntegrity.classify(
            storedRevision: 1, storedHash: "bad", canonical: canonical,
            properties: properties, body: body) == .HASH_MISMATCH)
        try expect(PacketMissionIntegrity.classify(
            storedRevision: 1, storedHash: hash, canonical: canonical,
            properties: properties, body: body, evidenceComplete: false) == .HASH_MISMATCH)
        try expect(PacketMissionIntegrity.classify(
            storedRevision: 1, storedHash: hash, canonical: canonical,
            properties: properties, body: body) == .CONSISTENT)
    }

    await test("Packet hydration envelope exposes bounded additive mission evidence") {
        let envelope = PacketRegistryEnvelope(
            primary: .init(id: "id", title: "P", lastEditedTime: "now", properties: .object([:])),
            body: "", relations: [:], fetchedAt: "now", warnings: [],
            missionIntegrity: .object([
                "classification": .string("CONSISTENT"),
                "revision": .int(1),
            ]))
        guard case .object(let object) = envelope.asValue() else { throw TestError.assertion("not object") }
        guard case .object(let evidence)? = object["missionIntegrity"] else { throw TestError.assertion("missing missionIntegrity") }
        try expect(evidence["classification"] == .string("CONSISTENT"))
        try expect(object["schemaVersion"] == .string("packet-registry-v1"))
    }
}
