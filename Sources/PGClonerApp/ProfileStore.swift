import Foundation
import PGClonerCore

actor ProfileStore {
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func load() throws -> [ConnectionProfile] {
        let url = try profilesURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode(
            [ConnectionProfile].self,
            from: Data(contentsOf: url)
        ).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ profiles: [ConnectionProfile]) throws {
        let url = try profilesURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }

    func importLegacyIfNeeded() throws -> [LegacyProfile] {
        guard try load().isEmpty else { return [] }
        let home = fileManager.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent(".pg_cloner", isDirectory: true)
        let files = [
            directory.appendingPathComponent("source_connections.json"),
            directory.appendingPathComponent("target_connections.json")
        ]

        var imported: [LegacyProfile] = []
        var seen = Set<String>()
        for file in files where fileManager.fileExists(atPath: file.path) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            guard let records = object as? [String: [String: Any]] else { continue }
            for (_, value) in records {
                let connectionType = value["connection_type"] as? String ?? "postgres"
                guard connectionType == "postgres" else { continue }
                let key = [
                    value["host"] as? String ?? "",
                    String(value["port"] as? Int ?? 5_432),
                    value["database"] as? String ?? "",
                    value["username"] as? String ?? ""
                ].joined(separator: "|")
                guard seen.insert(key).inserted else { continue }

                let authentication: AuthenticationMethod =
                    (value["auth_type"] as? String) == "azure_ad" ? .azureCLI : .password
                let profile = ConnectionProfile(
                    name: value["name"] as? String ?? "Imported connection",
                    host: value["host"] as? String ?? "localhost",
                    port: value["port"] as? Int ?? 5_432,
                    database: value["database"] as? String ?? "",
                    username: value["username"] as? String ?? "",
                    authentication: authentication,
                    tlsMode: (value["ssl"] as? Bool) == true ? .require : .disable
                )
                imported.append(
                    LegacyProfile(
                        profile: profile,
                        password: value["password"] as? String
                    )
                )
            }
        }
        return imported
    }

    func applicationSupportDirectory() throws -> URL {
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root.appendingPathComponent("PG Cloner", isDirectory: true)
    }

    private func profilesURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("profiles.json")
    }
}

struct LegacyProfile: Sendable {
    var profile: ConnectionProfile
    var password: String?
}
