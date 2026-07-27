import Foundation

public struct DDLGenerator: Sendable {
    public init() {}

    public func createSchema(for table: TableReference) -> String {
        "CREATE SCHEMA IF NOT EXISTS \(SQLIdentifier.quote(table.schema))"
    }

    public func dropTable(_ table: TableReference) -> String {
        "DROP TABLE IF EXISTS \(SQLIdentifier.quote(table)) CASCADE"
    }

    public func createTable(_ metadata: TableMetadata) throws -> String {
        guard !metadata.columns.isEmpty else {
            throw CloneEngineError.invalidMetadata(
                "\(metadata.reference.qualifiedName) has no columns."
            )
        }

        var definitions = metadata.columns.map(columnDefinition)
        if let primaryKey = metadata.primaryKey {
            definitions.append(
                "CONSTRAINT \(SQLIdentifier.quote(primaryKey.name)) \(primaryKey.definition)"
            )
        }

        return """
        CREATE TABLE \(SQLIdentifier.quote(metadata.reference)) (
          \(definitions.joined(separator: ",\n  "))
        )
        """
    }

    public func addForeignKey(
        _ foreignKey: ForeignKeyMetadata,
        targetTable: TableReference? = nil
    ) throws -> String {
        guard let definition = foreignKey.definition else {
            throw CloneEngineError.invalidMetadata(
                "Foreign key \(foreignKey.name) is missing its PostgreSQL definition."
            )
        }
        return """
        ALTER TABLE \(SQLIdentifier.quote(targetTable ?? foreignKey.childTable))
        ADD CONSTRAINT \(SQLIdentifier.quote(foreignKey.name)) \(definition)
        """
    }

    private func columnDefinition(_ column: ColumnMetadata) -> String {
        var parts = [SQLIdentifier.quote(column.name), column.typeName]

        if let expression = column.generatedExpression {
            parts.append("GENERATED ALWAYS AS (\(expression)) STORED")
        } else if let identity = column.identity {
            let generation = identity == .always ? "ALWAYS" : "BY DEFAULT"
            parts.append("GENERATED \(generation) AS IDENTITY")
        } else if let defaultExpression = column.defaultExpression.nilIfBlank {
            if let serial = serialType(for: column.typeName, defaultExpression: defaultExpression) {
                parts[1] = serial
            } else {
                parts.append("DEFAULT \(defaultExpression)")
            }
        }

        if !column.isNullable, column.generatedExpression == nil {
            parts.append("NOT NULL")
        }

        return parts.joined(separator: " ")
    }

    private func serialType(for typeName: String, defaultExpression: String) -> String? {
        guard defaultExpression.contains("nextval(") else { return nil }
        let normalized = typeName.lowercased()
        if normalized.contains("bigint") { return "BIGSERIAL" }
        if normalized.contains("smallint") { return "SMALLSERIAL" }
        if normalized.contains("integer") { return "SERIAL" }
        return nil
    }
}
