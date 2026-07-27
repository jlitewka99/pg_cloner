public struct UpsertSQLBuilder: Sendable {
    public init() {}

    public func statement(
        target: TableReference,
        stageTable: String,
        columns: [ColumnMetadata],
        stageColumnNames: [String]? = nil,
        primaryKey: PrimaryKeyMetadata
    ) throws -> String {
        guard !columns.isEmpty else {
            throw CloneEngineError.invalidMetadata(
                "Upsert for \(target.qualifiedName) has no copyable columns."
            )
        }

        let names = columns.map(\.name)
        let stageNames = stageColumnNames ?? names
        guard stageNames.count == names.count else {
            throw CloneEngineError.invalidMetadata(
                "Upsert stage has \(stageNames.count) columns for \(names.count) target columns."
            )
        }
        let quotedColumns = names.map(SQLIdentifier.quote).joined(separator: ", ")
        let quotedStageColumns = stageNames.map(SQLIdentifier.quote).joined(separator: ", ")
        let conflictTarget = primaryKey.columns.map(SQLIdentifier.quote).joined(separator: ", ")
        let immutableIdentityColumns = Set(
            columns.compactMap { column in
                column.identity == .always ? column.name : nil
            }
        )
        let updatable = names.filter {
            !primaryKey.columns.contains($0) && !immutableIdentityColumns.contains($0)
        }

        let conflictAction: String
        if updatable.isEmpty {
            conflictAction = "DO NOTHING"
        } else {
            let assignments = updatable.map {
                "\(SQLIdentifier.quote($0)) = EXCLUDED.\(SQLIdentifier.quote($0))"
            }.joined(separator: ", ")
            conflictAction = "DO UPDATE SET \(assignments)"
        }

        return """
        INSERT INTO \(SQLIdentifier.quote(target)) (\(quotedColumns))
        OVERRIDING SYSTEM VALUE
        SELECT \(quotedStageColumns) FROM \(SQLIdentifier.quote(stageTable))
        ON CONFLICT (\(conflictTarget)) \(conflictAction)
        """
    }
}
