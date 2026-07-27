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
