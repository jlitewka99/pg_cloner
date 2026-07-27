import Foundation

public enum TransformationRuleLoader {
    public static func bundledDefaults() throws -> TransformationRuleSet {
        let packagedBundle = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("PGCloner_PGClonerCore.bundle") }
            .flatMap(Bundle.init(url:))
        let url = packagedBundle?.url(
            forResource: "transformations",
            withExtension: "json"
        ) ?? Bundle.module.url(
            forResource: "transformations",
            withExtension: "json"
        )
        guard let url else {
            throw CloneEngineError.invalidMetadata(
                "Bundled transformation rules are missing."
            )
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> TransformationRuleSet {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TransformationRuleSet.self, from: data)
    }

    public static func save(_ rules: TransformationRuleSet, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: url, options: .atomic)
    }
}
