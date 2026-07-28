import Foundation
import Logging
import NIOCore
import PGClonerCore
import PostgresNIO

struct DataTransfer: Sendable {
    let logger: Logger
    let encoder = CopyTextEncoder()
    let transformer = TransformationEngine()
    let flushSize = 1_048_576

    func copy(
        source: PostgresConnection,
        target: PostgresConnection,
        metadata: TableMetadata,
        filter: SubsetQuery?,
        limit: Int?,
        transformations: [String: TransformationKind],
        conflictMode: ConflictMode,
        progress: @Sendable (TableProgress) -> Void
    ) async throws -> Int64 {
        let columns = metadata.copyableColumns
        guard !columns.isEmpty else { return 0 }

        let sourceQuery = PostgresQuerySupport(connection: source, logger: logger)
    let rowsTotal: Int64
    do {
      rowsTotal = try await count(
            query: sourceQuery,
            table: metadata.reference,
            filter: filter,
            limit: limit
        )
    } catch {
      throw CloneTableFailure.source(error)
    }
        progress(
            TableProgress(
                table: metadata.reference,
                phase: .counting,
                rowsTotal: rowsTotal
            )
        )
        guard rowsTotal > 0 else { return 0 }

        let select = try selectQuery(
            table: metadata.reference,
            columns: columns,
            filter: filter,
            limit: limit
        )
    let sourceRows: PostgresRowSequence
    do {
      sourceRows = try await source.query(select, logger: logger)
    } catch {
      throw CloneTableFailure.source(error)
    }
        let columnNames = columns.map(\.name)

        if conflictMode == .replace {
            return try await copyWithUpsert(
                sourceRows: sourceRows,
                target: target,
                metadata: metadata,
                columns: columns,
                transformations: transformations,
                rowsTotal: rowsTotal,
                progress: progress
            )
        }

        try await PostgresQuerySupport(connection: target, logger: logger).execute(
            "SET LOCAL search_path = \(SQLIdentifier.quote(metadata.reference.schema)), pg_catalog"
        )
        if !Self.copyAPIIdentifiersAreSafe(
            tableName: metadata.reference.name,
            columns: columnNames
        ) {
            return try await copyThroughSafeStage(
                sourceRows: sourceRows,
                target: target,
                metadata: metadata,
                columns: columns,
                transformations: transformations,
                rowsTotal: rowsTotal,
                progress: progress
            )
        }
        return try await write(
            sourceRows: sourceRows,
            target: target,
            copyTableName: metadata.reference.name,
            columnNames: columnNames,
            columns: columns,
            transformations: transformations,
            table: metadata.reference,
            rowsTotal: rowsTotal,
            progress: progress
        )
    }

    private func copyWithUpsert(
        sourceRows: PostgresRowSequence,
        target: PostgresConnection,
        metadata: TableMetadata,
        columns: [ColumnMetadata],
        transformations: [String: TransformationKind],
        rowsTotal: Int64,
        progress: @Sendable (TableProgress) -> Void
    ) async throws -> Int64 {
        guard let primaryKey = metadata.primaryKey else {
            throw CloneEngineError.missingPrimaryKey(metadata.reference)
        }

        let query = PostgresQuerySupport(connection: target, logger: logger)
    let stage =
      "pgcloner_stage_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let stageColumns = columns.indices.map { "pgcloner_c\($0)" }
    try await query.execute(
      try createSafeStageSQL(
            stage: stage,
            target: metadata.reference,
            columns: columns,
            aliases: stageColumns
        ))
        try await query.execute(
            "SET LOCAL search_path = pg_temp, \(SQLIdentifier.quote(metadata.reference.schema)), pg_catalog"
        )

        let copied = try await write(
            sourceRows: sourceRows,
            target: target,
            copyTableName: stage,
            columnNames: stageColumns,
            columns: columns,
            transformations: transformations,
            table: metadata.reference,
            rowsTotal: rowsTotal,
            progress: progress
        )

        try await query.execute(
            try UpsertSQLBuilder().statement(
                target: metadata.reference,
                stageTable: stage,
                columns: columns,
                stageColumnNames: stageColumns,
                primaryKey: primaryKey
            )
        )
        return copied
    }

    private func copyThroughSafeStage(
        sourceRows: PostgresRowSequence,
        target: PostgresConnection,
        metadata: TableMetadata,
        columns: [ColumnMetadata],
        transformations: [String: TransformationKind],
        rowsTotal: Int64,
        progress: @Sendable (TableProgress) -> Void
    ) async throws -> Int64 {
        let query = PostgresQuerySupport(connection: target, logger: logger)
    let stage =
      "pgcloner_stage_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let aliases = columns.indices.map { "pgcloner_c\($0)" }
    try await query.execute(
      try createSafeStageSQL(
            stage: stage,
            target: metadata.reference,
            columns: columns,
            aliases: aliases
        ))
        try await query.execute(
            "SET LOCAL search_path = pg_temp, \(SQLIdentifier.quote(metadata.reference.schema)), pg_catalog"
        )
        let copied = try await write(
            sourceRows: sourceRows,
            target: target,
            copyTableName: stage,
            columnNames: aliases,
            columns: columns,
            transformations: transformations,
            table: metadata.reference,
            rowsTotal: rowsTotal,
            progress: progress
        )

        let targetColumns = columns.map {
            SQLIdentifier.quote($0.name)
        }.joined(separator: ", ")
        let sourceColumns = aliases.map(SQLIdentifier.quote).joined(separator: ", ")
    let overriding =
      columns.contains { $0.identity == .always }
            ? "\nOVERRIDING SYSTEM VALUE"
            : ""
        try await query.execute(
            """
            INSERT INTO \(SQLIdentifier.quote(metadata.reference)) (\(targetColumns))\(overriding)
            SELECT \(sourceColumns) FROM \(SQLIdentifier.quote(stage))
            """
        )
        return copied
    }

    private func createSafeStageSQL(
        stage: String,
        target: TableReference,
        columns: [ColumnMetadata],
        aliases: [String]
    ) throws -> String {
        guard columns.count == aliases.count, !columns.isEmpty else {
            throw CloneEngineError.invalidMetadata(
                "Cannot create a COPY stage with mismatched columns."
            )
        }
        let projection = zip(columns, aliases).map { column, alias in
            "\(SQLIdentifier.quote(column.name)) AS \(SQLIdentifier.quote(alias))"
        }.joined(separator: ", ")
        return """
        CREATE TEMP TABLE \(SQLIdentifier.quote(stage))
        ON COMMIT DROP
        AS SELECT \(projection)
        FROM \(SQLIdentifier.quote(target))
        WITH NO DATA
        """
    }

    private static func copyAPIIdentifiersAreSafe(
        tableName: String,
        columns: [String]
    ) -> Bool {
        !tableName.contains("\"") && columns.allSatisfy { !$0.contains("\"") }
    }

    private func write(
        sourceRows: PostgresRowSequence,
        target: PostgresConnection,
        copyTableName: String,
        columnNames: [String],
        columns: [ColumnMetadata],
        transformations: [String: TransformationKind],
        table: TableReference,
        rowsTotal: Int64,
        progress: @Sendable (TableProgress) -> Void
    ) async throws -> Int64 {
        var copied: Int64 = 0
    do {
        try await target.copyFrom(
            table: copyTableName,
            columns: columnNames,
            format: .text(.init()),
            logger: logger
        ) { writer in
            var buffer = ByteBufferAllocator().buffer(capacity: flushSize)
        var iterator = sourceRows.makeAsyncIterator()

        while true {
          let row: PostgresRow?
          do {
            row = try await iterator.next()
          } catch {
            throw CloneTableFailure.source(error)
          }
          guard let row else { break }

                try Task.checkCancellation()
                let values = try Array(row).map { try $0.decode(String?.self) }
                let transformed = try transformer.transform(
                    row: values,
                    columns: columns,
                    transformations: transformations,
                    table: table
                )
                let data = encoder.encode(row: transformed)

                if buffer.readableBytes > 0, buffer.readableBytes + data.count > flushSize {
                    try await writer.write(buffer)
                    buffer.clear()
                    progress(
                        TableProgress(
                            table: table,
                            phase: .copying,
                            rowsCopied: copied,
                            rowsTotal: rowsTotal
                        )
                    )
                }

                buffer.writeBytes(data)
                copied += 1
            }

            if buffer.readableBytes > 0 {
                try await writer.write(buffer)
            }
        }
    } catch let failure as CloneTableFailure {
      throw failure
    } catch {
      throw CloneTableFailure.target(error)
    }

        progress(
            TableProgress(
                table: table,
                phase: .copying,
                rowsCopied: copied,
                rowsTotal: rowsTotal
            )
        )
        return copied
    }

    private func count(
        query: PostgresQuerySupport,
        table: TableReference,
        filter: SubsetQuery?,
        limit: Int?
    ) async throws -> Int64 {
        var inner = "SELECT 1 FROM \(SQLIdentifier.quote(table))"
        if let filter {
            inner += " WHERE \(filter.sql)"
        }
        if let limit {
            inner += " ORDER BY \(SQLIdentifier.quote(table)).ctid LIMIT \(limit)"
        }
        let sql = "SELECT count(*)::bigint FROM (\(inner)) pgcloner_count"
        let postgresQuery = try PostgresQuerySupport.query(
            sql,
            textArrayBindings: filter?.textArrayBindings ?? []
        )
        return try await query.scalarInt64(postgresQuery) ?? 0
    }

    private func selectQuery(
        table: TableReference,
        columns: [ColumnMetadata],
        filter: SubsetQuery?,
        limit: Int?
    ) throws -> PostgresQuery {
        let projection = columns.map {
            "\(SQLIdentifier.quote($0.name))::text AS \(SQLIdentifier.quote($0.name))"
        }.joined(separator: ", ")

        var sql = "SELECT \(projection) FROM \(SQLIdentifier.quote(table))"
        if let filter {
            sql += " WHERE \(filter.sql)"
        }
        if let limit {
            sql += " ORDER BY \(SQLIdentifier.quote(table)).ctid LIMIT \(limit)"
        }
        return try PostgresQuerySupport.query(
            sql,
            textArrayBindings: filter?.textArrayBindings ?? []
        )
    }
}
