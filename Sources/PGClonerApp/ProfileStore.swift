import Foundation
import PGClonerCore

enum ConnectionProfileRole: String, CaseIterable, Sendable {
    case source
    case target

    var displayName: String { rawValue.capitalized }

    fileprivate var fileName: String { "\(rawValue)_connections.json" }
}

actor ProfileStore {
    private let fileManager: FileManager
    private let applicationSupportDirectoryOverride: URL?
    private let previousApplicationSupportDirectoryOverride: URL?
    private let legacyDirectory: URL
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    init(
        applicationSupportDirectory: URL? = nil,
        previousApplicationSupportDirectory: URL? = nil,
        legacyDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        applicationSupportDirectoryOverride = applicationSupportDirectory
        previousApplicationSupportDirectoryOverride = previousApplicationSupportDirectory
        self.legacyDirectory = legacyDirectory
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                ".pg_cloner",
                isDirectory: true
            )
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

    /// Returns a one-time migration only before either role-specific store exists.
    func migrationIfNeeded() throws -> ProfileMigration? {
        guard try !hasRoleSpecificStore() else { return nil }

        let previousSource = try loadPreviousProfiles(for: .source)
        let previousTarget = try loadPreviousProfiles(for: .target)
        if !previousSource.isEmpty || !previousTarget.isEmpty {
            return ProfileMigration(
                kind: .previousApplicationSupport,
                source: previousSource.map { profile in
                    ImportedProfile(
                        profile: Self.copy(of: profile),
                        passwordSourceProfileID: profile.id
                    )
                },
                target: previousTarget.map { profile in
                    ImportedProfile(
                        profile: Self.copy(of: profile),
                        passwordSourceProfileID: profile.id
                    )
                }
            )
        }

        let previousUnifiedProfiles = try loadPreviousUnifiedProfiles()
        if !previousUnifiedProfiles.isEmpty {
            return ProfileMigration(
                kind: .previousApplicationSupport,
                source: previousUnifiedProfiles.map { profile in
                    ImportedProfile(
                        profile: Self.copy(of: profile),
                        passwordSourceProfileID: profile.id
                    )
                },
                target: previousUnifiedProfiles.map { profile in
                    ImportedProfile(
                        profile: Self.copy(of: profile),
                        passwordSourceProfileID: profile.id
                    )
                }
            )
        }

        let legacySource = try loadLegacyProfiles(for: .source)
        let legacyTarget = try loadLegacyProfiles(for: .target)
        if !legacySource.isEmpty || !legacyTarget.isEmpty {
            return ProfileMigration(
                kind: .legacyRoleSpecific,
                source: legacySource,
                target: legacyTarget
            )
        }

        let currentProfiles = try loadUnifiedProfiles()
        return ProfileMigration(
            kind: currentProfiles.isEmpty ? .empty : .unifiedProfiles,
            source: currentProfiles.map { profile in
                ImportedProfile(
                    profile: Self.copy(of: profile),
                    passwordSourceProfileID: profile.id
                )
            },
            target: currentProfiles.map { profile in
                ImportedProfile(
                    profile: Self.copy(of: profile),
                    passwordSourceProfileID: profile.id
                )
            }
        )
    }

    /// Copies non-profile settings from the previous shared app directory once.
    func copyPreviousConfigurationIfNeeded() throws {
        guard let previousDirectory = try previousApplicationSupportDirectory() else { return }

        let destinationDirectory = try applicationSupportDirectory()
        for fileName in ["clone_settings.json", "transformations.local.json"] {
            let source = previousDirectory.appendingPathComponent(fileName)
            let destination = destinationDirectory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else {
                continue
            }

            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        }
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
        return root.appendingPathComponent("PG Cloner Beta", isDirectory: true)
    }

    func profilesURL(for role: ConnectionProfileRole) throws -> URL {
        try applicationSupportDirectory().appendingPathComponent(role.fileName)
    }

    private func hasRoleSpecificStore() throws -> Bool {
        for role in ConnectionProfileRole.allCases {
            if fileManager.fileExists(atPath: try profilesURL(for: role).path) {
                return true
            }
        }
        return false
    }

    private func loadUnifiedProfiles() throws -> [ConnectionProfile] {
        try loadUnifiedProfiles(from: applicationSupportDirectory())
    }

    private func loadPreviousProfiles(for role: ConnectionProfileRole) throws -> [ConnectionProfile] {
        guard let directory = try previousApplicationSupportDirectory() else { return [] }
        let url = directory.appendingPathComponent(role.fileName)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([ConnectionProfile].self, from: Data(contentsOf: url))
            .sorted(by: Self.sortProfiles)
    }

    private func loadPreviousUnifiedProfiles() throws -> [ConnectionProfile] {
        guard let directory = try previousApplicationSupportDirectory() else { return [] }
        return try loadUnifiedProfiles(from: directory)
    }

    private func loadUnifiedProfiles(from directory: URL) throws -> [ConnectionProfile] {
        let url = directory.appendingPathComponent("profiles.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([ConnectionProfile].self, from: Data(contentsOf: url))
    }

    private func previousApplicationSupportDirectory() throws -> URL? {
        if let previousApplicationSupportDirectoryOverride {
            return previousApplicationSupportDirectoryOverride
        }
        guard applicationSupportDirectoryOverride == nil else { return nil }
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root.appendingPathComponent("PG Cloner", isDirectory: true)
    }

    private func loadLegacyProfiles(for role: ConnectionProfileRole) throws -> [ImportedProfile] {
        let url = legacyDirectory.appendingPathComponent(role.fileName)
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        let records = try decoder.decode(
            [String: LegacyConnectionRecord].self,
            from: Data(contentsOf: url)
        )
        return records.values.compactMap { record in
            guard (record.connectionType ?? "postgres") == "postgres" else { return nil }
            return ImportedProfile(
                profile: ConnectionProfile(
                    name: record.name ?? "Imported connection",
                    host: record.host ?? "localhost",
                    port: record.port ?? 5_432,
                    database: record.database ?? "",
                    username: record.username ?? "",
                    authentication: record.authType == "azure_ad" ? .azureCLI : .password,
                    tlsMode: record.ssl == true ? .require : .disable
                ),
                password: record.password
            )
        }.sorted { Self.sortProfiles($0.profile, $1.profile) }
    }

    private static func copy(of profile: ConnectionProfile) -> ConnectionProfile {
        ConnectionProfile(
            name: profile.name,
            host: profile.host,
            port: profile.port,
            database: profile.database,
            username: profile.username,
            authentication: profile.authentication,
            tlsMode: profile.tlsMode,
            azureCLIPath: profile.azureCLIPath
        )
    }

    private static func sortProfiles(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

struct ProfileMigration: Sendable {
    enum Kind: Equatable, Sendable {
        case previousApplicationSupport
        case legacyRoleSpecific
        case unifiedProfiles
        case empty
    }

    var kind: Kind
    var source: [ImportedProfile]
    var target: [ImportedProfile]
}

struct ImportedProfile: Sendable {
    var profile: ConnectionProfile
    var password: String?
    var passwordSourceProfileID: UUID?
}

private struct LegacyConnectionRecord: Decodable {
    var name: String?
    var host: String?
    var port: Int?
    var database: String?
    var username: String?
    var password: String?
    var ssl: Bool?
    var authType: String?
    var connectionType: String?

    enum CodingKeys: String, CodingKey {
        case name
        case host
        case port
        case database
        case username
        case password
        case ssl
        case authType = "auth_type"
        case connectionType = "connection_type"
    }
}
