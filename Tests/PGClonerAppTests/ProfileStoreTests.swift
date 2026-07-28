import Foundation
import PGClonerCore
import Testing

@testable import PGClonerApp

@Suite("ProfileStore")
struct ProfileStoreTests {
  @Test("Default storage is isolated from the original PG Cloner configuration")
  func usesBetaSpecificApplicationSupportDirectory() async throws {
    let store = ProfileStore()
    let directory = try await store.applicationSupportDirectory()
    let applicationSupport = try #require(
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    )

    #expect(directory == applicationSupport.appendingPathComponent("PG Cloner Beta", isDirectory: true))
    #expect(directory != applicationSupport.appendingPathComponent("PG Cloner", isDirectory: true))
  }

  @Test("Execution settings persist independently from connection profiles")
  func persistsExecutionSettings() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let appSupport = directory.appendingPathComponent("Application Support")
    let profiles = ProfileStore(applicationSupportDirectory: appSupport)
    let settings = CloneSettingsStore(profileStore: profiles)

    #expect(try await settings.load() == CloneExecutionOptions())

    let saved = CloneExecutionOptions(queryTimeoutSeconds: 90, retryAttempts: 4)
    try await settings.save(saved)
    #expect(try await settings.load() == saved)
    #expect(
      FileManager.default.fileExists(
        atPath: appSupport.appendingPathComponent("clone_settings.json").path
      )
    )
  }

  @Test("Source and target profiles are persisted independently")
    func keepsRoleSpecificProfilesSeparate() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProfileStore(
            applicationSupportDirectory: directory.appendingPathComponent("Application Support"),
            legacyDirectory: directory.appendingPathComponent("Legacy")
        )
        let source = profile(name: "Production source")
        let target = profile(name: "Development target")

        try await store.save(source, for: .source)
        try await store.save(target, for: .target)

        #expect(try await store.load(.source) == [source])
        #expect(try await store.load(.target) == [target])

        try await store.delete(profileID: source.id, from: .source)
        #expect(try await store.load(.source).isEmpty)
        #expect(try await store.load(.target) == [target])
    }

    @Test("Shared PG Cloner configuration is copied into isolated beta storage")
    func migratesSharedApplicationSupportConfiguration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let beta = directory.appendingPathComponent("PG Cloner Beta")
        let previous = directory.appendingPathComponent("PG Cloner")
        let legacy = directory.appendingPathComponent("Legacy")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)

        let source = profile(name: "Previous source")
        let target = profile(name: "Previous target")
        try JSONEncoder().encode([source]).write(
            to: previous.appendingPathComponent("source_connections.json"),
            options: .atomic
        )
        try JSONEncoder().encode([target]).write(
            to: previous.appendingPathComponent("target_connections.json"),
            options: .atomic
        )
        let settings = CloneExecutionOptions(queryTimeoutSeconds: 90, retryAttempts: 4)
        try JSONEncoder().encode(settings).write(
            to: previous.appendingPathComponent("clone_settings.json"),
            options: .atomic
        )
        let transformations = Data("{\"description\":\"Previous overrides\",\"rules\":[]}".utf8)
        try transformations.write(
            to: previous.appendingPathComponent("transformations.local.json"),
            options: .atomic
        )

        let store = ProfileStore(
            applicationSupportDirectory: beta,
            previousApplicationSupportDirectory: previous,
            legacyDirectory: legacy
        )
        let migration = try #require(try await store.migrationIfNeeded())
        let importedSource = try #require(migration.source.first)
        let importedTarget = try #require(migration.target.first)

        #expect(migration.kind == .previousApplicationSupport)
        #expect(importedSource.profile.id != source.id)
        #expect(importedTarget.profile.id != target.id)
        #expect(importedSource.passwordSourceProfileID == source.id)
        #expect(importedTarget.passwordSourceProfileID == target.id)

        try await store.save(migration.source.map(\.profile), for: .source)
        try await store.save(migration.target.map(\.profile), for: .target)
        try await store.copyPreviousConfigurationIfNeeded()

        let copiedSettings = try JSONDecoder().decode(
            CloneExecutionOptions.self,
            from: Data(contentsOf: beta.appendingPathComponent("clone_settings.json"))
        )
        #expect(copiedSettings == settings)
        #expect(
            try Data(contentsOf: beta.appendingPathComponent("transformations.local.json"))
                == transformations
        )
    }

    @Test("Legacy source and target files retain their roles during migration")
    func importsLegacyRoleSpecificFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appSupport = directory.appendingPathComponent("Application Support")
        let legacy = directory.appendingPathComponent("Legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try legacyJSON(
            name: "Legacy source",
            password: "source-secret",
            ssl: true
        ).write(
            to: legacy.appendingPathComponent("source_connections.json"),
            options: .atomic
        )
        try legacyJSON(
            name: "Legacy target",
            password: "target-secret",
            ssl: false
        ).write(
            to: legacy.appendingPathComponent("target_connections.json"),
            options: .atomic
        )

        let store = ProfileStore(applicationSupportDirectory: appSupport, legacyDirectory: legacy)
        let migration = try await store.migrationIfNeeded()

        #expect(migration?.kind == .legacyRoleSpecific)
        #expect(migration?.source.map(\.profile.name) == ["Legacy source"])
        #expect(migration?.target.map(\.profile.name) == ["Legacy target"])
        #expect(migration?.source.first?.password == "source-secret")
        #expect(migration?.target.first?.password == "target-secret")
        #expect(migration?.source.first?.profile.tlsMode == .require)
    }

    @Test("Unified profiles are copied to separate role-specific profiles")
    func migratesUnifiedProfilesWithNewIDs() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appSupport = directory.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let existing = profile(name: "Existing profile")
        let data = try JSONEncoder().encode([existing])
        try data.write(to: appSupport.appendingPathComponent("profiles.json"), options: .atomic)

        let store = ProfileStore(applicationSupportDirectory: appSupport)
        let migration = try await store.migrationIfNeeded()
        let source = try #require(migration?.source.first)
        let target = try #require(migration?.target.first)

        #expect(migration?.kind == .unifiedProfiles)
        #expect(source.profile.name == existing.name)
        #expect(target.profile.name == existing.name)
        #expect(source.profile.id != existing.id)
        #expect(target.profile.id != existing.id)
        #expect(source.profile.id != target.profile.id)
        #expect(source.passwordSourceProfileID == existing.id)
        #expect(target.passwordSourceProfileID == existing.id)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pg-cloner-profile-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func profile(name: String) -> ConnectionProfile {
        ConnectionProfile(
            name: name,
            host: "localhost",
            database: "postgres",
            username: "postgres"
        )
    }

    private func legacyJSON(name: String, password: String, ssl: Bool) -> Data {
        Data(
            """
            {
              "legacy-id": {
                "name": "\(name)",
                "host": "db.example.test",
                "port": 5432,
                "database": "postgres",
                "username": "postgres",
                "password": "\(password)",
                "ssl": \(ssl),
                "auth_type": "password",
                "connection_type": "postgres"
              }
            }
            """.utf8
        )
    }
}
