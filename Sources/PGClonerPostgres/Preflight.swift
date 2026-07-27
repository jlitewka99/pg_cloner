import Foundation
import Logging
import PGClonerCore
import PostgresNIO

public struct PreflightReport: Hashable, Sendable {
    public var warnings: [String]

    public init(warnings: [String] = []) {
        self.warnings = warnings
    }
}

struct Preflight: Sendable {
    let source: PostgresConnection
    let target: PostgresConnection
    let logger: Logger

    func run(
        plan: ClonePlan,
        metadata: [TableReference: TableMetadata],
        options: CopyOptions
    ) async throws -> PreflightReport {
        let sourceQuery = PostgresQuerySupport(connection: source, logger: logger)
        let targetQuery = PostgresQuerySupport(connection: target, logger: logger)
        let targetInspector = SchemaInspector(connection: target, logger: logger)
        let tableNames = plan.ordered.map(SQLIdentifier.quote)

        try await checkSourcePrivileges(query: sourceQuery, tableNames: tableNames)
        try checkSourceKeys(plan: plan, metadata: metadata, options: options)
        try await checkCustomTypes(
            sourceInspector: SchemaInspector(connection: source, logger: logger),
            targetQuery: targetQuery,
            tables: plan.ordered
        )

        if options.skipStructure {
            try await checkDataOnlyTarget(
                query: targetQuery,
                inspector: targetInspector,
                plan: plan,
                metadata: metadata,
                options: options,
                tableNames: tableNames
            )
        } else {
            try await checkStructurePrivileges(
                query: targetQuery,
                plan: plan,
                tableNames: tableNames
            )
            try await checkDestructiveDependencies(
                query: targetQuery,
                tableNames: tableNames
            )
        }

        return PreflightReport(
            warnings: plan.containsCycle
                ? ["The clone plan contains a foreign-key cycle."]
                : []
        )
    }

    private func checkSourcePrivileges(
        query: PostgresQuerySupport,
        tableNames: [String]
    ) async throws {
        let rows = try await query.rows(
            """
            SELECT requested.name::text
            FROM unnest($1::text[]) AS requested(name)
            WHERE to_regclass(requested.name) IS NULL
               OR NOT has_table_privilege(current_user, requested.name, 'SELECT')
            ORDER BY requested.name
            """,
            textArrayBindings: [tableNames]
        )
        let missing = try rows.map {
            "SELECT on \(try Array($0).requiredString(0, field: "source table"))"
        }
        if !missing.isEmpty {
            throw CloneEngineError.insufficientPrivileges(missing)
        }
    }

    private func checkSourceKeys(
        plan: ClonePlan,
        metadata: [TableReference: TableMetadata],
        options: CopyOptions
    ) throws {
        guard options.conflictMode == .replace else { return }
        for table in plan.ordered where metadata[table]?.primaryKey == nil {
            throw CloneEngineError.missingPrimaryKey(table)
        }
    }

    private func checkCustomTypes(
        sourceInspector: SchemaInspector,
        targetQuery: PostgresQuerySupport,
        tables: [TableReference]
    ) async throws {
        let customTypes = try await sourceInspector.customTypes(for: tables)
        guard !customTypes.isEmpty else { return }

        let rows = try await targetQuery.rows(
            """
            SELECT required.required_type::text
            FROM unnest($1::text[]) AS required(required_type)
            WHERE to_regtype(required.required_type) IS NULL
            ORDER BY required.required_type
            """,
            textArrayBindings: [customTypes]
        )
        let missing = try rows.map {
            try Array($0).requiredString(0, field: "missing type")
        }
        if !missing.isEmpty {
            throw CloneEngineError.unsupportedTypes(missing)
        }
    }

    private func checkStructurePrivileges(
        query: PostgresQuerySupport,
        plan: ClonePlan,
        tableNames: [String]
    ) async throws {
        let schemaNames = Array(Set(plan.ordered.map(\.schema))).sorted()
        let schemaRows = try await query.rows(
            """
            SELECT requested.schema_name::text
            FROM unnest($1::text[]) AS requested(schema_name)
            WHERE CASE
              WHEN to_regnamespace(requested.schema_name) IS NULL
                THEN NOT has_database_privilege(current_user, current_database(), 'CREATE')
              ELSE NOT (
                has_schema_privilege(current_user, requested.schema_name, 'USAGE')
                AND has_schema_privilege(current_user, requested.schema_name, 'CREATE')
              )
            END
            ORDER BY requested.schema_name
            """,
            textArrayBindings: [schemaNames]
        )
        var missing = try schemaRows.map {
            "USAGE/CREATE on schema \(try Array($0).requiredString(0, field: "target schema"))"
        }

        let ownerRows = try await query.rows(
            """
            SELECT requested.name::text
            FROM unnest($1::text[]) AS requested(name)
            JOIN pg_class relation ON relation.oid = to_regclass(requested.name)
            WHERE NOT pg_has_role(relation.relowner, 'USAGE')
            ORDER BY requested.name
            """,
            textArrayBindings: [tableNames]
        )
        missing += try ownerRows.map {
            "ownership of \(try Array($0).requiredString(0, field: "target table"))"
        }

        if !missing.isEmpty {
            throw CloneEngineError.insufficientPrivileges(missing)
        }
    }

    private func checkDataOnlyTarget(
        query: PostgresQuerySupport,
        inspector: SchemaInspector,
        plan: ClonePlan,
        metadata: [TableReference: TableMetadata],
        options: CopyOptions,
        tableNames: [String]
    ) async throws {
        let privilege = options.conflictMode == .replace ? "INSERT,UPDATE" : "INSERT"
        let rows = try await query.rows(
            """
            SELECT requested.name::text,
                   (to_regclass(requested.name) IS NULL)::text,
                   CASE
                     WHEN to_regclass(requested.name) IS NULL THEN false
                     ELSE has_table_privilege(current_user, requested.name, '\(privilege)')
                   END::text
            FROM unnest($1::text[]) AS requested(name)
            WHERE to_regclass(requested.name) IS NULL
               OR NOT has_table_privilege(current_user, requested.name, '\(privilege)')
            ORDER BY requested.name
            """,
            textArrayBindings: [tableNames]
        )

        var compatibilityProblems: [String] = []
        var privilegeProblems: [String] = []
        for row in rows {
            let cells = Array(row)
            let tableName = try cells.requiredString(0, field: "target table")
            if try cells.requiredString(1, field: "missing target flag") == "true" {
                compatibilityProblems.append("\(tableName) does not exist.")
            } else {
                privilegeProblems.append("\(privilege) on \(tableName)")
            }
        }
        if !privilegeProblems.isEmpty {
            throw CloneEngineError.insufficientPrivileges(privilegeProblems)
        }
        if !compatibilityProblems.isEmpty {
            throw CloneEngineError.incompatibleTarget(compatibilityProblems)
        }

        for table in plan.ordered {
            guard let sourceMetadata = metadata[table] else {
                throw CloneEngineError.invalidMetadata(
                    "Metadata for \(table.qualifiedName) is missing."
                )
            }
            let targetColumns = try await inspector.columns(for: table)
            compatibilityProblems += Self.columnCompatibilityProblems(
                source: sourceMetadata.copyableColumns,
                target: targetColumns,
                table: table
            )

            if options.conflictMode == .replace {
                let targetKey = try await inspector.primaryKey(for: table)
                if targetKey?.columns != sourceMetadata.primaryKey?.columns {
                    compatibilityProblems.append(
                        "\(table.qualifiedName) has a different target primary key."
                    )
                }
            }
        }

        if !compatibilityProblems.isEmpty {
            throw CloneEngineError.incompatibleTarget(compatibilityProblems)
        }
    }

    private static func columnCompatibilityProblems(
        source: [ColumnMetadata],
        target: [ColumnMetadata],
        table: TableReference
    ) -> [String] {
        let sourceByName = Dictionary(uniqueKeysWithValues: source.map { ($0.name, $0) })
        let targetByName = Dictionary(uniqueKeysWithValues: target.map { ($0.name, $0) })
        var problems: [String] = []

        for sourceColumn in source {
            guard let targetColumn = targetByName[sourceColumn.name] else {
                problems.append(
                    "\(table.qualifiedName) is missing column \(sourceColumn.name)."
                )
                continue
            }
            if normalizedType(sourceColumn.typeName) != normalizedType(targetColumn.typeName) {
                problems.append(
                    "\(table.qualifiedName).\(sourceColumn.name) has type "
                        + "\(targetColumn.typeName), expected \(sourceColumn.typeName)."
                )
            }
        }

        for targetColumn in target where sourceByName[targetColumn.name] == nil {
            let suppliesItsOwnValue = targetColumn.isNullable
                || targetColumn.defaultExpression != nil
                || targetColumn.generatedExpression != nil
                || targetColumn.identity != nil
            if !suppliesItsOwnValue {
                problems.append(
                    "\(table.qualifiedName).\(targetColumn.name) is required by the target."
                )
            }
        }
        return problems
    }

    private static func normalizedType(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "character varying", with: "varchar")
            .replacingOccurrences(of: "timestamp without time zone", with: "timestamp")
            .replacingOccurrences(of: "timestamp with time zone", with: "timestamptz")
            .replacingOccurrences(of: "double precision", with: "float8")
            .replacingOccurrences(of: " ", with: "")
    }

    private func checkDestructiveDependencies(
        query: PostgresQuerySupport,
        tableNames: [String]
    ) async throws {
        let rows = try await query.rows(
            """
            WITH requested(name) AS (
              SELECT unnest($1::text[])
            ),
            planned(name, oid) AS (
              SELECT name, to_regclass(name)
              FROM requested
              WHERE to_regclass(name) IS NOT NULL
            ),
            dependencies(description) AS (
              SELECT DISTINCT format(
                '%I.%I constraint %I',
                child_ns.nspname,
                child.relname,
                con.conname
              )::text
              FROM pg_constraint con
              JOIN pg_class child ON child.oid = con.conrelid
              JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
              JOIN planned parent ON parent.oid = con.confrelid
              WHERE con.contype = 'f'
                AND child.oid NOT IN (SELECT oid FROM planned)

              UNION

              SELECT DISTINCT format(
                '%I.%I %s',
                dependent_ns.nspname,
                dependent.relname,
                CASE dependent.relkind WHEN 'm' THEN 'materialized view' ELSE 'view' END
              )::text
              FROM pg_depend dependency
              JOIN pg_rewrite rewrite ON rewrite.oid = dependency.objid
              JOIN pg_class dependent ON dependent.oid = rewrite.ev_class
              JOIN pg_namespace dependent_ns ON dependent_ns.oid = dependent.relnamespace
              JOIN planned referenced ON referenced.oid = dependency.refobjid
              WHERE dependent.relkind IN ('v', 'm')
                AND dependent.oid NOT IN (SELECT oid FROM planned)

              UNION

              SELECT DISTINCT format(
                '%I.%I trigger %I',
                relation_ns.nspname,
                relation.relname,
                trigger.tgname
              )::text
              FROM pg_trigger trigger
              JOIN pg_class relation ON relation.oid = trigger.tgrelid
              JOIN pg_namespace relation_ns ON relation_ns.oid = relation.relnamespace
              JOIN planned target ON target.oid = relation.oid
              WHERE NOT trigger.tgisinternal

              UNION

              SELECT DISTINCT format(
                '%I.%I policy %I',
                relation_ns.nspname,
                relation.relname,
                policy.polname
              )::text
              FROM pg_policy policy
              JOIN pg_class relation ON relation.oid = policy.polrelid
              JOIN pg_namespace relation_ns ON relation_ns.oid = relation.relnamespace
              JOIN planned target ON target.oid = relation.oid

              UNION

              SELECT DISTINCT format(
                '%I.%I inherited child',
                child_ns.nspname,
                child.relname
              )::text
              FROM pg_inherits inheritance
              JOIN planned parent ON parent.oid = inheritance.inhparent
              JOIN pg_class child ON child.oid = inheritance.inhrelid
              JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
              WHERE child.oid NOT IN (SELECT oid FROM planned)
            )
            SELECT description::text
            FROM dependencies
            ORDER BY description
            """,
            textArrayBindings: [tableNames]
        )
        let dependencies = try rows.map {
            try Array($0).requiredString(0, field: "external dependency")
        }
        if !dependencies.isEmpty {
            throw CloneEngineError.destructiveDependencies(dependencies)
        }
    }
}
