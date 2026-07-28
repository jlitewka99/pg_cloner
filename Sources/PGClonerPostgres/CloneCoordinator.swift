import Foundation
import Logging
import PGClonerCore
import PostgresNIO

public actor CloneCoordinator {
    private let credentials: any DatabaseCredentialProvider
    private let factory: PostgresConnectionFactory
    private let logger: Logger
    private var activeTask: Task<Void, Never>?

    public init(
        credentials: any DatabaseCredentialProvider,
        logger: Logger = Logger(label: "PGCloner.Clone")
    ) {
        self.credentials = credentials
        self.factory = PostgresConnectionFactory(logger: logger)
        self.logger = logger
    }

    public var isRunning: Bool { activeTask != nil }

    public func testConnection(_ profile: ConnectionProfile) async throws -> String {
        let password = try await credentials.password(for: profile)
        let connection = try await factory.connect(
            profile: profile,
            password: password,
            connectionID: 100
        )
        do {
            let query = PostgresQuerySupport(connection: connection, logger: logger)
            let version = try await query.scalarString("SELECT version()::text") ?? "PostgreSQL"
            try await connection.closeGracefully()
            return version
        } catch {
            try? await connection.closeGracefully()
            throw error
        }
    }

    public func schemas(source profile: ConnectionProfile) async throws -> [String] {
        let connection = try await open(profile, id: 101)
        do {
            let schemas = try await SchemaInspector(
                connection: connection,
                logger: logger
            ).schemas()
            try await connection.closeGracefully()
            return schemas
        } catch {
            try? await connection.closeGracefully()
            throw error
        }
    }

    public func tables(
        source profile: ConnectionProfile,
        schema: String
    ) async throws -> [TableSummary] {
        let connection = try await open(profile, id: 102)
        do {
            let tables = try await SchemaInspector(
                connection: connection,
                logger: logger
            ).tables(in: schema)
            try await connection.closeGracefully()
            return tables
        } catch {
            try? await connection.closeGracefully()
            throw error
        }
    }

    public func plan(
        source profile: ConnectionProfile,
        selectedTables: [TableReference]
    ) async throws -> ClonePlan {
        let connection = try await open(profile, id: 103)
        do {
            let foreignKeys = try await SchemaInspector(
                connection: connection,
                logger: logger
            ).allForeignKeys()
            let plan = DependencyGraph(foreignKeys: foreignKeys).plan(for: selectedTables)
            try await connection.closeGracefully()
            return plan
        } catch {
            try? await connection.closeGracefully()
            throw error
        }
    }

    public func suggestedTransformations(
        source profile: ConnectionProfile,
        tables: [TableReference],
        rules: TransformationRuleSet
    ) async throws -> [String: TransformationKind] {
        let connection = try await open(profile, id: 104)
        do {
            let inspector = SchemaInspector(connection: connection, logger: logger)
            var output: [String: TransformationKind] = [:]
            for table in tables {
                let columns = try await inspector.columns(for: table)
                for (column, strategy) in rules.transformations(
                    for: table,
                    columns: columns.filter { !$0.isGenerated }
                ) {
                    output["\(table.qualifiedName).\(column)"] = strategy
                }
            }
            try await connection.closeGracefully()
            return output
        } catch {
            try? await connection.closeGracefully()
            throw error
        }
    }

    public func start(
        request: CloneRequest,
        sourceProfile: ConnectionProfile,
        targetProfile: ConnectionProfile
    ) throws -> AsyncStream<CloneEvent> {
        guard activeTask == nil else { throw CloneEngineError.alreadyRunning }
        guard !request.selectedTables.isEmpty else { throw CloneEngineError.noTablesSelected }
        guard !Self.sameDatabase(sourceProfile, targetProfile) else {
            throw CloneEngineError.sameSourceAndTarget
        }
        _ = try request.options.validated()
    _ = try request.executionOptions.validated()

        let (stream, continuation) = AsyncStream.makeStream(of: CloneEvent.self)
        continuation.onTermination = { @Sendable [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancel() }
        }
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await self.execute(
                request: request,
                sourceProfile: sourceProfile,
                targetProfile: targetProfile,
                continuation: continuation
            )
        }
        activeTask = task
        return stream
    }

    public func cancel() {
        activeTask?.cancel()
    }

    private static func sameDatabase(
        _ source: ConnectionProfile,
        _ target: ConnectionProfile
    ) -> Bool {
        source.host.caseInsensitiveCompare(target.host) == .orderedSame
            && source.port == target.port
            && source.database.caseInsensitiveCompare(target.database) == .orderedSame
    }

    private func open(_ profile: ConnectionProfile, id: Int) async throws -> PostgresConnection {
        let password = try await credentials.password(for: profile)
        return try await factory.connect(profile: profile, password: password, connectionID: id)
    }

    private func execute(
        request: CloneRequest,
        sourceProfile: ConnectionProfile,
        targetProfile: ConnectionProfile,
        continuation: AsyncStream<CloneEvent>.Continuation
    ) async {
        let startedAt = Date()
        var outcomes: [TableReference: TableCloneOutcome] = [:]
        var plannedTables = request.selectedTables
        var wasCancelled = false
        var terminalReason = "Clone did not reach this table."
        var source: PostgresConnection?
        var target: PostgresConnection?
    var clonePlan: ClonePlan?
    var cloneMetadata: [TableReference: TableMetadata]?

        func emitLog(_ level: LogLevel, _ message: String) {
            continuation.yield(.log(CloneLogEntry(level: level, message: message)))
        }

        do {
            emitLog(.info, "Connecting to source and target databases")
            async let sourceConnection = open(sourceProfile, id: 1)
            async let targetConnection = open(targetProfile, id: 2)
            source = try await sourceConnection
            target = try await targetConnection
      guard source != nil, target != nil else {
                throw CloneEngineError.database("Could not establish both database connections.")
            }
      try await applyQueryTimeout(
        request.executionOptions,
        to: target!
      )

      var sourceRetryAttempts: [TableReference: Int] = [:]
      sourceClone: while true {
        do {
          try await source!.withTransaction(logger: logger) { sourceTransaction in
                try await PostgresQuerySupport(
                    connection: sourceTransaction,
                    logger: logger
                ).execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            try await applyQueryTimeout(
              request.executionOptions,
              to: sourceTransaction,
              local: true
            )

                let inspector = SchemaInspector(connection: sourceTransaction, logger: logger)
                let foreignKeys = try await inspector.allForeignKeys()
                let plan = DependencyGraph(foreignKeys: foreignKeys).plan(
                    for: request.selectedTables
                )
                plannedTables = plan.ordered
                let metadata = try await loadMetadata(
                    plan: plan,
                    inspector: inspector,
                    foreignKeys: foreignKeys
                )
            clonePlan = plan
            cloneMetadata = metadata

                continuation.yield(
                    .progress(
                        TableProgress(
                            table: plan.ordered.first ?? TableReference(name: "preflight"),
                            phase: .preflight
                        )
                    )
                )
                let report = try await Preflight(
                    source: sourceTransaction,
              target: target!,
                    logger: logger
                ).run(plan: plan, metadata: metadata, options: request.options)
                for warning in report.warnings {
                    emitLog(.warning, warning)
                }

                let filters = selectedFilters(request: request, selected: Set(plan.selected))
                let subset = await SubsetPlanner().plan(
                    cloneOrder: plan.ordered,
                    foreignKeys: foreignKeys,
                    selected: Set(plan.selected),
                    filters: filters
                ) { subsetQuery in
                    let rows = try await PostgresQuerySupport(
                        connection: sourceTransaction,
                        logger: logger
                    ).rows(
                        subsetQuery.sql,
                        textArrayBindings: subsetQuery.textArrayBindings
                    )
                    return try rows.compactMap { try Array($0).string(0) }
                }

                continuation.yield(.started(plan))
                emitLog(.info, "Clone plan contains \(plan.ordered.count) tables")

                var tableFailure: String?
            for table in plan.ordered where outcomes[table] == nil {
                    try Task.checkCancellation()
                    guard let tableMetadata = metadata[table] else {
                        throw CloneEngineError.invalidMetadata(
                            "Metadata for \(table.qualifiedName) is missing."
                        )
                    }

                    let tableFilter: SubsetQuery?
                    let limit: Int?
                    if plan.selected.contains(table) {
                        let filter = filters[table]
                        tableFilter = filter?.whereClause.map { SubsetQuery(sql: $0) }
                        limit = filter?.limit
                    } else {
                        tableFilter = SubsetPlanner().requiredPredicate(
                            for: table,
                            resolution: subset[table],
                            foreignKeys: foreignKeys,
                            cloneSet: Set(plan.ordered),
                            selected: Set(plan.selected),
                            filters: filters
                        )
                        limit = nil
                    }

                    do {
                let cloned = try await cloneTableWithRetry(
                            source: sourceTransaction,
                  target: target!,
                  targetProfile: targetProfile,
                            metadata: tableMetadata,
                            filter: tableFilter,
                            limit: limit,
                            options: request.options,
                  executionOptions: request.executionOptions,
                            continuation: continuation
                        )
                target = cloned.target
                outcomes[table] = .completed(rows: cloned.rows)
                emitLog(.success, "Completed \(table.qualifiedName): \(cloned.rows) rows")
                    } catch is CancellationError {
                        outcomes[table] = .rolledBack(message: "Cancelled")
                        continuation.yield(
                            .progress(TableProgress(table: table, phase: .cancelled))
                        )
                        throw CancellationError()
              } catch let failure as CloneTableFailure {
                if case .source(let error) = failure {
                  throw SourceTableRetryRequired(table: table, underlying: error)
                }
                let message = PostgresConnectionFactory.safeMessage(failure.underlying)
                outcomes[table] = .rolledBack(message: message)
                continuation.yield(
                  .progress(TableProgress(table: table, phase: .failed))
                )
                emitLog(.error, "\(table.qualifiedName) rolled back: \(message)")
                tableFailure = message
                break
                    } catch {
                        if Task.isCancelled {
                            outcomes[table] = .rolledBack(message: "Cancelled")
                            continuation.yield(
                                .progress(TableProgress(table: table, phase: .cancelled))
                            )
                            throw CancellationError()
                        }
                        let message = PostgresConnectionFactory.safeMessage(error)
                        outcomes[table] = .rolledBack(message: message)
                        continuation.yield(
                            .progress(TableProgress(table: table, phase: .failed))
                        )
                        emitLog(.error, "\(table.qualifiedName) rolled back: \(message)")
                        tableFailure = message
                        break
                    }
                }

                if let tableFailure {
                    terminalReason = "Skipped after an earlier table failed: \(tableFailure)"
                    for table in plan.ordered where outcomes[table] == nil {
                        outcomes[table] = .skipped(reason: terminalReason)
                    }
                }

          }
          break sourceClone
        } catch let retry as SourceTableRetryRequired {
          let attempt = (sourceRetryAttempts[retry.table] ?? 0) + 1
          sourceRetryAttempts[retry.table] = attempt
          guard CloneRetryPolicy.isRetryable(retry.underlying),
            attempt <= request.executionOptions.retryAttempts
          else {
            let message = PostgresConnectionFactory.safeMessage(retry.underlying)
            outcomes[retry.table] = .rolledBack(message: message)
            continuation.yield(
              .progress(TableProgress(table: retry.table, phase: .failed))
            )
            terminalReason = "Skipped after an earlier table failed: \(message)"
            emitLog(
              .error,
              "\(retry.table.qualifiedName) rolled back after \(attempt - 1) retries: \(message)")
            break sourceClone
          }

          emitLog(
            .warning,
            "Source connection was restarted for \(retry.table.qualifiedName); retry \(attempt) of \(request.executionOptions.retryAttempts). The clone is no longer guaranteed to use one snapshot across all tables."
          )
          try await Task.sleep(for: CloneRetryPolicy.delay(forRetry: attempt))
          try? await source?.closeGracefully()
          source = try await open(sourceProfile, id: 1)
        }
      }

      if let clonePlan, let cloneMetadata {
                if !request.options.skipStructure {
          let eligible = Set(
            outcomes.compactMap { table, outcome in
                        if case .completed = outcome { return table }
                        return nil
                    })
                    let finalizationFailures = try await finalizeSchema(
            target: target!,
            plan: clonePlan,
            metadata: cloneMetadata,
                        eligibleTables: eligible,
                        continuation: continuation
                    )
                    for (table, message) in finalizationFailures {
                        outcomes[table] = .failed(message: message)
                        continuation.yield(
                            .progress(TableProgress(table: table, phase: .failed))
                        )
                        emitLog(.error, "\(table.qualifiedName) finalization failed: \(message)")
                    }
                    for table in eligible where finalizationFailures[table] == nil {
                        continuation.yield(
                            .progress(TableProgress(table: table, phase: .completed))
                        )
                    }
                } else {
          for table in clonePlan.ordered {
                        if case .completed = outcomes[table] {
                            continuation.yield(
                                .progress(TableProgress(table: table, phase: .completed))
                            )
                        }
                    }
                }
            }
        } catch is CancellationError {
            wasCancelled = true
            terminalReason = "Skipped because the clone was cancelled."
            emitLog(.warning, "Clone cancelled; the active table was rolled back")
        } catch {
            if Task.isCancelled {
                wasCancelled = true
                terminalReason = "Skipped because the clone was cancelled."
                emitLog(.warning, "Clone cancelled; the active table was rolled back")
            } else {
                terminalReason = PostgresConnectionFactory.safeMessage(error)
                emitLog(.error, terminalReason)
            }
        }

        for table in plannedTables where outcomes[table] == nil {
            outcomes[table] = .skipped(reason: terminalReason)
        }

        if let source { try? await source.closeGracefully() }
        if let target { try? await target.closeGracefully() }

        let result = CloneResult(
            startedAt: startedAt,
            outcomes: outcomes,
            wasCancelled: wasCancelled
        )
        continuation.yield(.finished(result))
        continuation.finish()
        activeTask = nil
    }

    private func loadMetadata(
        plan: ClonePlan,
        inspector: SchemaInspector,
        foreignKeys: [ForeignKeyMetadata]
    ) async throws -> [TableReference: TableMetadata] {
        var output: [TableReference: TableMetadata] = [:]
        for table in plan.ordered {
            output[table] = try await inspector.metadata(
                for: table,
                knownForeignKeys: foreignKeys
            )
        }
        return output
    }

    private func selectedFilters(
        request: CloneRequest,
        selected: Set<TableReference>
    ) -> [TableReference: TableFilter] {
    Dictionary(
      uniqueKeysWithValues: selected.map { table in
            let local = request.perTableOptions[table]
            return (
                table,
                TableFilter(
                    limit: local?.limit ?? request.options.limit,
                    whereClause: local?.whereClause ?? request.options.whereClause
                )
            )
        })
    }

    private func cloneTable(
        source: PostgresConnection,
        target: PostgresConnection,
        metadata: TableMetadata,
        filter: SubsetQuery?,
        limit: Int?,
        options: CopyOptions,
        continuation: AsyncStream<CloneEvent>.Continuation
    ) async throws -> Int64 {
    do {
      return try await target.withTransaction(logger: logger) { transaction in
            let query = PostgresQuerySupport(connection: transaction, logger: logger)
            if !options.skipStructure {
                continuation.yield(
                    .progress(TableProgress(table: metadata.reference, phase: .creatingStructure))
                )
                let ddl = DDLGenerator()
                try await query.execute(ddl.dropTable(metadata.reference))
                try await query.execute(ddl.createSchema(for: metadata.reference))
                try await query.execute(try ddl.createTable(metadata))
            }

            let copied = try await DataTransfer(logger: logger).copy(
                source: source,
                target: transaction,
                metadata: metadata,
                filter: filter,
                limit: limit,
                transformations: options.transformations,
                conflictMode: options.conflictMode,
                progress: { continuation.yield(.progress($0)) }
            )

            continuation.yield(
                .progress(TableProgress(table: metadata.reference, phase: .synchronizingSequence))
            )
            try await synchronizeSequences(
                query: query,
                metadata: metadata
            )
            return copied
        }
    } catch let failure as CloneTableFailure {
      throw failure
    } catch {
      throw CloneTableFailure.target(error)
    }
  }

  private func cloneTableWithRetry(
    source: PostgresConnection,
    target: PostgresConnection,
    targetProfile: ConnectionProfile,
    metadata: TableMetadata,
    filter: SubsetQuery?,
    limit: Int?,
    options: CopyOptions,
    executionOptions: CloneExecutionOptions,
    continuation: AsyncStream<CloneEvent>.Continuation
  ) async throws -> (rows: Int64, target: PostgresConnection) {
    var activeTarget = target
    var retries = 0

    while true {
      do {
        let rows = try await cloneTable(
          source: source,
          target: activeTarget,
          metadata: metadata,
          filter: filter,
          limit: limit,
          options: options,
          continuation: continuation
        )
        return (rows, activeTarget)
      } catch is CancellationError {
        throw CancellationError()
      } catch let failure as CloneTableFailure {
        guard case .target(let error) = failure else { throw failure }
        guard CloneRetryPolicy.isRetryable(error), retries < executionOptions.retryAttempts else {
          throw failure
        }

        retries += 1
        continuation.yield(
          .log(
            CloneLogEntry(
              level: .warning,
              message:
                "Retrying \(metadata.reference.qualifiedName) after transient target error (attempt \(retries) of \(executionOptions.retryAttempts))."
            )
          )
        )
        try await Task.sleep(for: CloneRetryPolicy.delay(forRetry: retries))
        try Task.checkCancellation()

        // A failed COPY can leave the protocol session unusable. A fresh target connection
        // also handles server-side disconnects and gets the same statement timeout.
        try? await activeTarget.closeGracefully()
        activeTarget = try await open(targetProfile, id: 2)
        try await applyQueryTimeout(executionOptions, to: activeTarget)
      }
    }
  }

  private func applyQueryTimeout(
    _ options: CloneExecutionOptions,
    to connection: PostgresConnection,
    local: Bool = false
  ) async throws {
    let validated = try options.validated()
    let milliseconds = validated.queryTimeoutSeconds * 1_000
    let scope = local ? "LOCAL " : ""
    try await PostgresQuerySupport(connection: connection, logger: logger).execute(
      "SET \(scope)statement_timeout = \(milliseconds)"
    )
    }

    private func synchronizeSequences(
        query: PostgresQuerySupport,
        metadata: TableMetadata
    ) async throws {
        for sequence in metadata.sequences {
            let maxSQL = """
                SELECT COALESCE(MAX(\(SQLIdentifier.quote(sequence.column))), 0)::bigint
                FROM \(SQLIdentifier.quote(metadata.reference))
                """
            let maximum = try await query.scalarInt64(PostgresQuery(unsafeSQL: maxSQL)) ?? 0
            guard maximum > 0 else { continue }

            let tableName = SQLIdentifier.quote(metadata.reference)
            let setValue: PostgresQuery = """
                SELECT setval(
                  pg_get_serial_sequence(\(tableName), \(sequence.column)),
                  \(maximum),
                  true
                )
                """
            _ = try await query.execute(setValue)
        }
    }

    private func finalizeSchema(
        target: PostgresConnection,
        plan: ClonePlan,
        metadata: [TableReference: TableMetadata],
        eligibleTables: Set<TableReference>,
        continuation: AsyncStream<CloneEvent>.Continuation
    ) async throws -> [TableReference: String] {
        var failures: [TableReference: [String]] = [:]

        for table in plan.ordered where eligibleTables.contains(table) {
            guard let tableMetadata = metadata[table] else { continue }
            do {
                try await target.withTransaction(logger: logger) { connection in
                    let query = PostgresQuerySupport(connection: connection, logger: logger)
                    continuation.yield(
                        .progress(TableProgress(table: table, phase: .creatingIndexes))
                    )
                    for index in tableMetadata.indexes {
                        try await query.execute(index.definition)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures[table, default: []].append(
                    "Indexes: \(PostgresConnectionFactory.safeMessage(error))"
                )
            }
        }

        for table in plan.ordered where eligibleTables.contains(table) {
            guard let tableMetadata = metadata[table] else { continue }
            let unavailableParents = tableMetadata.foreignKeys
                .map(\.parentTable)
                .filter { plan.ordered.contains($0) && !eligibleTables.contains($0) }
            if !unavailableParents.isEmpty {
                failures[table, default: []].append(
                    "Foreign keys skipped because parent tables were not completed: "
                        + unavailableParents.map(\.qualifiedName).joined(separator: ", ")
                )
                continue
            }

            do {
                try await target.withTransaction(logger: logger) { connection in
                    let query = PostgresQuerySupport(connection: connection, logger: logger)
                    continuation.yield(
                        .progress(TableProgress(table: table, phase: .creatingForeignKeys))
                    )
                    for foreignKey in tableMetadata.foreignKeys {
                        try await query.execute(
                            try DDLGenerator().addForeignKey(foreignKey)
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures[table, default: []].append(
                    "Foreign keys: \(PostgresConnectionFactory.safeMessage(error))"
                )
            }
        }

        return failures.mapValues { $0.joined(separator: " ") }
    }
}

extension PostgresQuerySupport {
  fileprivate func scalarString(_ sql: String) async throws -> String? {
        try await scalarString(PostgresQuery(unsafeSQL: sql))
    }
}
