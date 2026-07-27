import Foundation

public enum SQLIdentifier {
    public static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    public static func quote(_ table: TableReference) -> String {
        "\(quote(table.schema)).\(quote(table.name))"
    }

    public static func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
