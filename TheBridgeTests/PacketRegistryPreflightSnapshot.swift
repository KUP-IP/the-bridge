import Foundation
import TheBridgeLib

struct PacketRegistryPreflightSnapshot: Codable {
    struct Property: Codable {
        let key: String
        let notionName: String
        let notionPropertyId: String?
        let type: String
        let role: String?
    }

    struct Entity: Codable {
        let key: String
        let displayName: String
        let dataSourceId: String
        let workspace: String?
        let properties: [Property]
        let cacheTTLSeconds: Int?
        let hasBody: Bool?
    }

    struct Column: Codable {
        let name: String
        let id: String
        let type: String
        let options: [String]?
        let relationDataSourceId: String?
    }

    let contractVersion: String?
    let entities: [Entity]
    let columns: [Column]

    func evaluate() -> [PacketRegistryPreflight.Defect] {
        let config = RegistryConfig(entities: entities.map { entity in
            RegistryEntity(
                key: entity.key,
                displayName: entity.displayName,
                dataSourceId: entity.dataSourceId,
                workspace: entity.workspace,
                properties: entity.properties.map { property in
                    RegistryProperty(
                        key: property.key,
                        notionName: property.notionName,
                        notionPropertyId: property.notionPropertyId,
                        type: property.type,
                        role: property.role.flatMap(RegistryPropertyRole.init(rawValue:)) ?? .generic)
                },
                cacheTTLSeconds: entity.cacheTTLSeconds ?? 300,
                hasBody: entity.hasBody ?? false)
        })
        let schema = DataSourceSchema(columnsByName: Dictionary(uniqueKeysWithValues: columns.map { column in
            (column.name, DataSourceSchema.Column(
                id: column.id,
                type: column.type,
                options: column.options ?? [],
                relationDataSourceId: column.relationDataSourceId))
        }))
        guard contractVersion == nil || contractVersion == PacketRegistryContract.version else {
            return [.init(
                code: "UNSUPPORTED_CONTRACT_VERSION",
                field: "contractVersion",
                expected: PacketRegistryContract.version,
                actual: contractVersion ?? "")]
        }
        return PacketRegistryPreflight.evaluate(config: config, schema: schema)
    }
}

/// Test-executable evidence mode. This evaluates a captured live snapshot using
/// the exact production preflight code without loading credentials, contacting
/// Notion, mutating config, binding properties, or touching caches.
func packetRegistryPreflightSnapshotExitCodeIfRequested() -> Int32? {
    let arguments = CommandLine.arguments
    guard let marker = arguments.firstIndex(of: "--packet-registry-preflight-snapshot") else { return nil }
    guard arguments.indices.contains(marker + 1) else {
        fputs("missing snapshot path\n", stderr)
        return 64
    }

    do {
        let url = URL(fileURLWithPath: arguments[marker + 1])
        let snapshot = try JSONDecoder().decode(
            PacketRegistryPreflightSnapshot.self,
            from: Data(contentsOf: url))
        let defects = snapshot.evaluate()
        let payload: [String: Any] = [
            "result": defects.isEmpty ? "PASS" : "DRIFT",
            "contractVersion": snapshot.contractVersion ?? PacketRegistryContract.version,
            "canonicalEntity": "packet",
            "defectCount": defects.count,
            "defects": defects.map { defect in
                [
                    "code": defect.code,
                    "field": defect.field,
                    "expected": defect.expected,
                    "actual": defect.actual,
                ]
            },
            "snapshotPath": url.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        return defects.isEmpty ? 0 : 2
    } catch {
        fputs("packet preflight snapshot error: \(error)\n", stderr)
        return 65
    }
}
