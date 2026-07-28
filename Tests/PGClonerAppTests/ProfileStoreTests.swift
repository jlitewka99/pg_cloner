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

    #expect(directory == applicationSupport.appendingPathComponent("PG Cloner Isolated", isDirectory: true))
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
            applicationSupportDirectory: directory.appendingPathComponent("Application Support")
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

    @Test("Existing PG Cloner connection profiles are ignored")
    func ignoresExistingPGClonerConfiguration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let beta = directory.appendingPathComponent("PG Cloner Isolated")
        let previous = directory.appendingPathComponent("PG Cloner")
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

        let store = ProfileStore(
            applicationSupportDirectory: beta
        )
        let cloneSettings = CloneSettingsStore(profileStore: store)

        #expect(try await store.load(.source).isEmpty)
        #expect(try await store.load(.target).isEmpty)
        #expect(try await cloneSettings.load() == CloneExecutionOptions())

        try await store.save(profile(name: "New source"), for: .source)
        #expect(try await store.load(.source).map(\.name) == ["New source"])
        #expect(try await store.load(.target).isEmpty)
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
}
