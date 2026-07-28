import Foundation
import PGClonerCore

actor RuleStore {
    private let profileStore: ProfileStore

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
    }

    func load() async throws -> (defaults: TransformationRuleSet, local: TransformationRuleSet) {
        let defaults = try TransformationRuleLoader.bundledDefaults()
        let url = try await localURL()
        let local: TransformationRuleSet
        if FileManager.default.fileExists(atPath: url.path) {
            local = try TransformationRuleLoader.load(from: url)
        } else {
            local = TransformationRuleSet(
                description: "Local transformation overrides"
            )
        }
        return (defaults, local)
    }

    func save(_ rules: TransformationRuleSet) async throws {
        try await TransformationRuleLoader.save(rules, to: localURL())
    }

    private func localURL() async throws -> URL {
        try await profileStore.applicationSupportDirectory()
            .appendingPathComponent("transformations.local.json")
    }
}

actor CloneSettingsStore {
  private let profileStore: ProfileStore
  private let decoder = JSONDecoder()
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  init(profileStore: ProfileStore) {
    self.profileStore = profileStore
  }

  func load() async throws -> CloneExecutionOptions {
    let url = try await settingsURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .init()
    }
    return try decoder.decode(CloneExecutionOptions.self, from: Data(contentsOf: url)).validated()
  }

  func save(_ options: CloneExecutionOptions) async throws {
    let validated = try options.validated()
    let url = try await settingsURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(validated).write(to: url, options: .atomic)
  }

  private func settingsURL() async throws -> URL {
    try await profileStore.applicationSupportDirectory()
      .appendingPathComponent("clone_settings.json")
  }
}
