import Foundation

public struct TransformationEngine: Sendable {
    public init() {}

    public func transform(
        row: [String?],
        columns: [ColumnMetadata],
        transformations: [String: TransformationKind],
        table: TableReference? = nil
    ) throws -> [String?] {
        guard row.count == columns.count else {
            throw CloneEngineError.invalidMetadata(
                "Received \(row.count) values for \(columns.count) columns."
            )
        }

        return zip(row, columns).map { value, column in
            let qualifiedKey = table.map {
                "\($0.qualifiedName).\(column.name)"
            }
            let shortTableKey = table.map {
                "\($0.name).\(column.name)"
            }
            let transformation = qualifiedKey.flatMap { transformations[$0] }
                ?? shortTableKey.flatMap { transformations[$0] }
                ?? transformations[column.name]
            guard let value, let transformation else {
                return value
            }
            return apply(transformation, to: value)
        }
    }

    public func apply(_ transformation: TransformationKind, to value: String) -> String {
        switch transformation {
        case .rot13:
            return String(value.unicodeScalars.map(Self.rot13))
        case .reverse:
            return String(value.reversed())
        case .add100:
            guard var number = Decimal(
                string: value,
                locale: Locale(identifier: "en_US_POSIX")
            ) else {
                return value
            }
            guard number != 0 else { return value }
            number += 100
            return NSDecimalNumber(decimal: number).stringValue
        }
    }

    private static func rot13(_ scalar: UnicodeScalar) -> Character {
        let value = scalar.value
        switch value {
        case 65...90:
            return Character(UnicodeScalar(65 + (value - 65 + 13) % 26)!)
        case 97...122:
            return Character(UnicodeScalar(97 + (value - 97 + 13) % 26)!)
        default:
            return Character(scalar)
        }
    }
}

public struct TransformationRuleSet: Codable, Hashable, Sendable {
    public struct PatternRule: Codable, Hashable, Sendable {
        public var pattern: String
        public var strategy: TransformationKind
        public var description: String

        public init(pattern: String, strategy: TransformationKind, description: String = "") {
            self.pattern = pattern
            self.strategy = strategy
            self.description = description
        }
    }

    public var version: String
    public var description: String
    public var columnPatterns: [PatternRule]
    public var tableSpecific: [String: [String: TransformationKind?]]
    public var excludePatterns: [String]

    public init(
        version: String = "1.0",
        description: String = "",
        columnPatterns: [PatternRule] = [],
        tableSpecific: [String: [String: TransformationKind?]] = [:],
        excludePatterns: [String] = []
    ) {
        self.version = version
        self.description = description
        self.columnPatterns = columnPatterns
        self.tableSpecific = tableSpecific
        self.excludePatterns = excludePatterns
    }

    enum CodingKeys: String, CodingKey {
        case version
        case description
        case columnPatterns = "column_patterns"
        case tableSpecific = "table_specific"
        case excludePatterns = "exclude_patterns"
    }

    public func transformations(
        for table: TableReference,
        columns: [ColumnMetadata]
    ) -> [String: TransformationKind] {
        var output: [String: TransformationKind] = [:]

        for column in columns {
            if matchesAny(excludePatterns, value: column.name) { continue }

            let tableRules = tableSpecific[table.qualifiedName] ?? tableSpecific[table.name]
            if let tableRules, tableRules.keys.contains(column.name) {
                if let storedValue = tableRules[column.name],
                   let strategy = storedValue
                {
                    output[column.name] = strategy
                }
                continue
            }

            if let rule = columnPatterns.first(where: {
                matches($0.pattern, value: column.name)
            }) {
                output[column.name] = rule.strategy
            }
        }

        return output
    }

    public func merged(over defaults: TransformationRuleSet) -> TransformationRuleSet {
        let localPatterns = Set(columnPatterns.map(\.pattern))
        let patterns = columnPatterns + defaults.columnPatterns.filter {
            !localPatterns.contains($0.pattern)
        }

        var tables = defaults.tableSpecific
        for (table, rules) in tableSpecific {
            tables[table, default: [:]].merge(rules) { _, local in local }
        }

        return TransformationRuleSet(
            version: version,
            description: description.isEmpty ? defaults.description : description,
            columnPatterns: patterns,
            tableSpecific: tables,
            excludePatterns: Array(Set(defaults.excludePatterns + excludePatterns)).sorted()
        )
    }

    private func matchesAny(_ patterns: [String], value: String) -> Bool {
        patterns.contains { matches($0, value: value) }
    }

    private func matches(_ pattern: String, value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }
}
