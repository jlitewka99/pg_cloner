import Foundation

public enum SubsetResolution: Hashable, Sendable {
    case materialized(keyColumn: String, values: [String])
    case empty(keyColumn: String)
    case nestedSQL
}

public struct SubsetQuery: Hashable, Sendable {
    public var sql: String
    public var textArrayBindings: [[String]]

    public init(sql: String, textArrayBindings: [[String]] = []) {
        self.sql = sql
        self.textArrayBindings = textArrayBindings
    }
}

public struct SubsetPlanner: Sendable {
    public typealias DistinctValueRunner = @Sendable (SubsetQuery) async throws -> [String]

    public var threshold: Int

    public init(threshold: Int = 5_000) {
        self.threshold = threshold
    }

    public func plan(
        cloneOrder: [TableReference],
        foreignKeys: [ForeignKeyMetadata],
        selected: Set<TableReference>,
        filters: [TableReference: TableFilter],
        runDistinct: DistinctValueRunner
    ) async -> [TableReference: SubsetResolution] {
        let cloneSet = Set(cloneOrder)
        var resolutions: [TableReference: SubsetResolution] = [:]

        for table in cloneOrder.reversed() where !selected.contains(table) {
            let inbound = foreignKeys.filter {
                $0.parentTable == table
                    && cloneSet.contains($0.childTable)
                    && $0.childTable != table
            }

            guard let keyColumn = singleSharedParentColumn(inbound) else {
                resolutions[table] = .nestedSQL
                continue
            }

            do {
                var values = Set<String>()
                var mustFallback = false

                for foreignKey in inbound {
                    guard foreignKey.childColumns.count == 1 else {
                        mustFallback = true
                        break
                    }

                    let query: SubsetQuery
                    if selected.contains(foreignKey.childTable) {
                        query = selectedValuesQuery(
                            foreignKey: foreignKey,
                            filter: filters[foreignKey.childTable]
                        )
                    } else {
                        guard let childResolution = resolutions[foreignKey.childTable] else {
                            mustFallback = true
                            break
                        }
                        switch childResolution {
                        case let .materialized(childKey, childValues):
                            query = requiredValuesQuery(
                                foreignKey: foreignKey,
                                childKey: childKey,
                                childValues: childValues
                            )
                        case .empty:
                            continue
                        case .nestedSQL:
                            mustFallback = true
                            continue
                        }
                    }

                    values.formUnion(try await runDistinct(query))
                    if values.count > threshold {
                        mustFallback = true
                        break
                    }
                }

                if mustFallback {
                    resolutions[table] = .nestedSQL
                } else if values.isEmpty {
                    resolutions[table] = .empty(keyColumn: keyColumn)
                } else {
                    resolutions[table] = .materialized(
                        keyColumn: keyColumn,
                        values: values.sorted()
                    )
                }
            } catch {
                resolutions[table] = .nestedSQL
            }
        }

        return resolutions
    }

    public func requiredPredicate(
        for parent: TableReference,
        resolution: SubsetResolution?,
        foreignKeys: [ForeignKeyMetadata],
        cloneSet: Set<TableReference>,
        selected: Set<TableReference>,
        filters: [TableReference: TableFilter]
    ) -> SubsetQuery? {
        switch resolution {
        case let .materialized(keyColumn, values):
            return SubsetQuery(
                sql: "\(SQLIdentifier.quote(keyColumn))::text = ANY($1::text[])",
                textArrayBindings: [values]
            )
        case let .empty(keyColumn):
            return SubsetQuery(
                sql: "\(SQLIdentifier.quote(keyColumn))::text = ANY($1::text[])",
                textArrayBindings: [[]]
            )
        case .nestedSQL, nil:
            return nestedRequiredPredicate(
                parent: parent,
                foreignKeys: foreignKeys,
                cloneSet: cloneSet,
                selected: selected,
                filters: filters
            )
        }
    }

    private func singleSharedParentColumn(_ foreignKeys: [ForeignKeyMetadata]) -> String? {
        let candidates = Set(foreignKeys.map(\.parentColumns))
        guard candidates.count == 1, let columns = candidates.first, columns.count == 1 else {
            return nil
        }
        return columns[0]
    }

    private func selectedValuesQuery(
        foreignKey: ForeignKeyMetadata,
        filter: TableFilter?
    ) -> SubsetQuery {
        let table = SQLIdentifier.quote(foreignKey.childTable)
        let column = SQLIdentifier.quote(foreignKey.childColumns[0])
        var base = "SELECT \(column)::text AS value FROM \(table)"
        if let whereClause = filter?.whereClause.nilIfBlank {
            base += " WHERE \(whereClause)"
        }

        if let limit = filter?.limit {
            base += " ORDER BY \(table).ctid LIMIT \(limit)"
            return SubsetQuery(
                sql: "SELECT DISTINCT value FROM (\(base)) limited WHERE value IS NOT NULL"
            )
        }

        return SubsetQuery(
            sql: "SELECT DISTINCT value FROM (\(base)) scoped WHERE value IS NOT NULL"
        )
    }

    private func requiredValuesQuery(
        foreignKey: ForeignKeyMetadata,
        childKey: String,
        childValues: [String]
    ) -> SubsetQuery {
        let table = SQLIdentifier.quote(foreignKey.childTable)
        let childColumn = SQLIdentifier.quote(foreignKey.childColumns[0])
        let key = SQLIdentifier.quote(childKey)
        return SubsetQuery(
            sql: """
            SELECT DISTINCT \(childColumn)::text AS value
            FROM \(table)
            WHERE \(key)::text = ANY($1::text[]) AND \(childColumn) IS NOT NULL
            """,
            textArrayBindings: [childValues]
        )
    }

    private func nestedRequiredPredicate(
        parent: TableReference,
        foreignKeys: [ForeignKeyMetadata],
        cloneSet: Set<TableReference>,
        selected: Set<TableReference>,
        filters: [TableReference: TableFilter]
    ) -> SubsetQuery? {
        var aliasCounter = 0
        var activePath: Set<TableReference> = []
        return nestedPredicate(
            for: parent,
            foreignKeys: foreignKeys,
            cloneSet: cloneSet,
            selected: selected,
            filters: filters,
            aliasCounter: &aliasCounter,
            activePath: &activePath
        ).map { SubsetQuery(sql: $0) }
    }

    private func nestedPredicate(
        for parent: TableReference,
        foreignKeys: [ForeignKeyMetadata],
        cloneSet: Set<TableReference>,
        selected: Set<TableReference>,
        filters: [TableReference: TableFilter],
        aliasCounter: inout Int,
        activePath: inout Set<TableReference>
    ) -> String? {
        if activePath.contains(parent) { return nil }
        activePath.insert(parent)
        defer { activePath.remove(parent) }

        let inbound = foreignKeys.filter {
            $0.parentTable == parent
                && cloneSet.contains($0.childTable)
                && $0.childTable != parent
        }

        let predicates = inbound.compactMap { foreignKey -> String? in
            let alias = "s\(aliasCounter)"
            aliasCounter += 1
            let childRef = SQLIdentifier.quote(foreignKey.childTable)
            let parentRef = SQLIdentifier.quote(parent)

            let parentColumns = foreignKey.parentColumns
                .map { "\(parentRef).\(SQLIdentifier.quote($0))" }
                .joined(separator: ", ")
            let childColumns = foreignKey.childColumns
                .map { "\(alias).\(SQLIdentifier.quote($0))" }
                .joined(separator: ", ")
            let childNonNull = foreignKey.childColumns
                .map { "\(alias).\(SQLIdentifier.quote($0)) IS NOT NULL" }
                .joined(separator: " AND ")

            var scopes: [String] = []
            if selected.contains(foreignKey.childTable) {
                if let whereClause = filters[foreignKey.childTable]?.whereClause.nilIfBlank {
                    scopes.append("(\(whereClause))")
                }
            } else if let nested = nestedPredicate(
                for: foreignKey.childTable,
                foreignKeys: foreignKeys,
                cloneSet: cloneSet,
                selected: selected,
                filters: filters,
                aliasCounter: &aliasCounter,
                activePath: &activePath
            ) {
                scopes.append("(\(nested))")
            } else {
                return nil
            }
            scopes.append(childNonNull)

            let whereSQL = scopes.joined(separator: " AND ")
            let limitSQL: String
            if selected.contains(foreignKey.childTable),
               let limit = filters[foreignKey.childTable]?.limit
            {
                limitSQL = " ORDER BY \(alias).ctid LIMIT \(limit)"
            } else {
                limitSQL = ""
            }

            return """
            (\(parentColumns)) IN (
              SELECT \(childColumns)
              FROM \(childRef) \(alias)
              WHERE \(whereSQL)\(limitSQL)
            )
            """
        }

        guard !predicates.isEmpty else { return nil }
        return predicates.map { "(\($0))" }.joined(separator: " OR ")
    }
}
