import Foundation
import TheBridgeLib

private func packetProperty(_ field: PacketRegistryContract.Field) -> RegistryProperty {
    RegistryProperty(
        key: field.key,
        notionName: field.notionName,
        notionPropertyId: "id_\(field.key)",
        type: field.type
    )
}

private func packetConfig(includeLegacyDuplicate: Bool = false) -> RegistryConfig {
    let packet = RegistryEntity(
        key: "packet",
        displayName: "PACKETS",
        dataSourceId: "packets-ds",
        properties: PacketRegistryContract.fields
            .filter(\.registryBindingRequired)
            .map(packetProperty),
        cacheTTLSeconds: 300,
        hasBody: true
    )
    let project = RegistryEntity(key: "project", displayName: "Projects", dataSourceId: "projects-ds", properties: [], cacheTTLSeconds: 300)
    let skill = RegistryEntity(key: "skill", displayName: "Skills", dataSourceId: "skills-ds", properties: [], cacheTTLSeconds: 300)
    let telemetry = RegistryEntity(key: "telemetry", displayName: "Telemetry", dataSourceId: "telemetry-ds", properties: [], cacheTTLSeconds: 300)
    let schedule = RegistryEntity(key: "schedule", displayName: "Schedule", dataSourceId: "schedule-ds", properties: [], cacheTTLSeconds: 300)
    let client = RegistryEntity(key: "client", displayName: "Clients", dataSourceId: "clients-ds", properties: [], cacheTTLSeconds: 300)
    var entities = [packet, project, skill, telemetry, schedule, client]
    if includeLegacyDuplicate {
        entities.insert(RegistryEntity(
            key: "session", displayName: packet.displayName,
            dataSourceId: packet.dataSourceId, properties: packet.properties,
            cacheTTLSeconds: packet.cacheTTLSeconds, hasBody: packet.hasBody
        ), at: 0)
    }
    return RegistryConfig(entities: entities)
}

private func packetSchema() -> DataSourceSchema {
    var columns: [String: DataSourceSchema.Column] = [:]
    for field in PacketRegistryContract.fields {
        let target: String?
        switch field.relationTargetEntity {
        case "packet": target = "packets-ds"
        case "project": target = "projects-ds"
        case "skill": target = "skills-ds"
        case "telemetry": target = "telemetry-ds"
        case "schedule": target = "schedule-ds"
        case "client": target = "clients-ds"
        default: target = nil
        }
        columns[field.notionName] = .init(
            id: "id_\(field.key)",
            type: field.type,
            options: field.expectedOptions.sorted(),
            relationDataSourceId: target
        )
    }
    return DataSourceSchema(columnsByName: columns)
}

private func codes(_ report: PacketRegistryPreflight.Report) -> Set<String> {
    Set(report.defects.map(\.code))
}

func runPacketRegistryPreflightTests() async {
    print("\n📦 PACKETS canonical binding + schema preflight")

    await test("Packet preflight: complete 34-column contract passes") {
        let report = PacketRegistryPreflight.evaluate(config: packetConfig(), schema: packetSchema())
        try expect(report.passes, "unexpected defects: \(report.defects)")
        try expect(report.classifiedColumnCount == 34)
        try expect(report.liveColumnCount == 34)
    }

    await test("Packet preflight: duplicate session and packet bindings fail closed") {
        let report = PacketRegistryPreflight.evaluate(
            config: packetConfig(includeLegacyDuplicate: true),
            schema: packetSchema()
        )
        try expect(codes(report).contains("DUPLICATE_BINDING"))
        try expect(report.bindingCandidates == ["packet", "session"])
    }

    await test("Packet preflight: legacy session-only binding is deterministic but not healthy") {
        var config = packetConfig()
        var legacy = config.entities.removeFirst()
        legacy = RegistryEntity(
            key: "session", displayName: legacy.displayName,
            dataSourceId: legacy.dataSourceId, properties: legacy.properties,
            cacheTTLSeconds: legacy.cacheTTLSeconds, hasBody: legacy.hasBody
        )
        config.entities.insert(legacy, at: 0)
        try expect(config.entity("packet")?.key == "packet")
        try expect(config.entity("session")?.key == "packet")
        try expect(codes(PacketRegistryPreflight.evaluate(config: config, schema: packetSchema())).contains("LEGACY_BINDING_ALIAS"))
    }

    await test("Packet preflight: genuine Sessions entity is not treated as PACKETS") {
        let sessions = RegistryEntity(
            key: "session", displayName: "Sessions", dataSourceId: "sessions-ds",
            properties: [RegistryProperty(key: "name", notionName: "Session Name", type: "title")],
            cacheTTLSeconds: 300)
        var config = packetConfig()
        config.entities.insert(sessions, at: 0)
        try expect(config.entity("session")?.dataSourceId == "sessions-ds")
        try expect(PacketRegistryContract.configuredEntities(in: config).count == 1)
    }

    await test("Packet preflight: added live column is explicitly unclassified") {
        var columns = packetSchema().columnsByName
        columns["Surprise"] = .init(id: "surprise", type: "rich_text")
        let report = PacketRegistryPreflight.evaluate(
            config: packetConfig(), schema: DataSourceSchema(columnsByName: columns)
        )
        try expect(report.defects.contains { $0.code == "UNCLASSIFIED_COLUMN" && $0.field == "Surprise" })

        var renamedColumns = packetSchema().columnsByName
        let objective = renamedColumns.removeValue(forKey: "Objective")!
        renamedColumns["Mission Objective"] = objective
        let renamed = PacketRegistryPreflight.evaluate(
            config: packetConfig(), schema: DataSourceSchema(columnsByName: renamedColumns)
        )
        try expect(renamed.defects.contains {
            $0.code == "RENAMED_COLUMN" && $0.field == "objective" && $0.actual == "Mission Objective"
        })
    }

    await test("Packet preflight: binding id, options, and relation targets are validated") {
        var config = packetConfig()
        var packet = config.entities[0]
        let objective = packet.properties.firstIndex { $0.key == "objective" }!
        packet.properties[objective].notionPropertyId = "stale-objective-id"
        config.entities[0] = packet

        var columns = packetSchema().columnsByName
        columns["Status"] = .init(id: "id_status", type: "status", options: ["QUEUE"])
        columns["PROJECT"] = .init(id: "id_project", type: "relation", relationDataSourceId: "wrong-projects")
        let report = PacketRegistryPreflight.evaluate(
            config: config, schema: DataSourceSchema(columnsByName: columns)
        )
        try expect(codes(report).isSuperset(of: ["BINDING_ID_MISMATCH", "OPTION_MISMATCH", "RELATION_TARGET_MISMATCH"]))
    }

    await test("Packet schema decoder retains options and relation target metadata") {
        let raw: [String: Any] = ["properties": [
            "Status": ["id": "status-id", "type": "status", "status": ["options": [["name": "QUEUE"], ["name": "Done"]]]],
            "PROJECT": ["id": "project-id", "type": "relation", "relation": ["data_source_id": "projects-ds"]],
        ]]
        let schema = RegistryRowDecoder.schema(from: raw)
        try expect(schema.column(named: "Status")?.options == ["Done", "QUEUE"])
        try expect(schema.column(named: "PROJECT")?.relationDataSourceId == "projects-ds")
        try expect(schema.column(withID: "project-id")?.name == "PROJECT")
    }
}
