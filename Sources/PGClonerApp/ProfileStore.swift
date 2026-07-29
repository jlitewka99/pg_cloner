import Foundation
import PGClonerCore

enum ConnectionProfileRole: String, CaseIterable, Sendable {
    case source
    case target

    var displayName: String { rawValue.capitalized }

    fileprivate var fileName: String { "\(rawValue)_connections.json" }
}

/// Stores this app's connection profiles independently of every previous PG Cloner installation.
actor ProfileStore {
    private let fileManager: FileManager
    private let applicationSupportDirectoryOverride: URL?
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        applicationSupportDirectoryOverride = applicationSupportDirectory
    }

    func load(_ role: ConnectionProfileRole) throws -> [ConnectionProfile] {
        let url = try profilesURL(for: role)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode(
            [ConnectionProfile].self,
            from: Data(contentsOf: url)
        ).sorted(by: Self.sortProfiles)
    }

    func save(_ profiles: [ConnectionProfile], for role: ConnectionProfileRole) throws {
        let url = try profilesURL(for: role)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(profiles.sorted(by: Self.sortProfiles)).write(to: url, options: .atomic)
    }

    func save(_ profile: ConnectionProfile, for role: ConnectionProfileRole) throws {
        var profiles = try load(role)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try save(profiles, for: role)
    }

    func delete(profileID: UUID, from role: ConnectionProfileRole) throws {
        try save(load(role).filter { $0.id != profileID }, for: role)
    }

    func applicationSupportDirectory() throws -> URL {
        if let applicationSupportDirectoryOverride {
            return applicationSupportDirectoryOverride
        }
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root.appendingPathComponent("PG Cloner Isolated", isDirectory: true)
    }

    func profilesURL(for role: ConnectionProfileRole) throws -> URL {
        try applicationSupportDirectory().appendingPathComponent(role.fileName)
    }

    private static func sortProfiles(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
