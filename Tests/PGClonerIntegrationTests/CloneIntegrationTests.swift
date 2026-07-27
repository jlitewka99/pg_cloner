import Foundation
import Logging
import PGClonerCore
import PGClonerPostgres
import PostgresNIO
import Testing

private let integrationConfiguration = IntegrationConfiguration.fromEnvironment()

@Suite(
    "PostgreSQL integration",
    .serialized,
    .enabled(
        if: integrationConfiguration != nil,
        "Set PGCLONER_TEST_PORT to run against the Docker test database."
    )
)
struct CloneIntegrationTests {
    @Test("Structure, PostgreSQL values, FK subset, and upsert")
    func completeCloneAndUpsert() async throws {
        let configuration = try #require(integrationConfiguration)
        try await configuration.withDatabases { source, target, password in
            try await prepareRepresentativeSource(source, password: password)
            let coordinator = coordinator(password: password)
            let request = CloneRequest(
                sourceProfileID: source.id,
                targetProfileID: target.id,
                selectedTables: [TableReference(name: "orders")],
                options: CopyOptions(
                    whereClause: "status = 'active'",
                    requireFilter: true,
                    transformations: [
                        "public.customers.email": .rot13
                    ]
                )
            )

            let first = try await runClone(
                coordinator: coordinator,
                request: request,
                source: source,
                target: target
            )
            #expect(first.result.isCompleteSuccess)
            #expect(first.plan.required == [TableReference(name: "customers")])

            try await withConnection(target, password: password, id: 31) { targetConnection in
                let customerCount = try await scalarInt(
                    targetConnection,
                    "SELECT count(*)::bigint FROM customers"
                )
                let orderCount = try await scalarInt(
                    targetConnection,
                    "SELECT count(*)::bigint FROM orders"
                )
                let orphanCount = try await scalarInt(
                    targetConnection,
                    """
                    SELECT count(*)::bigint
                    FROM orders child
                    LEFT JOIN customers parent ON parent.id = child.customer_id
                    WHERE parent.id IS NULL
                    """
                )
                let email = try await scalarString(
                    targetConnection,
                    "SELECT email::text FROM customers WHERE id = 1"
                )
                let bytea = try await scalarString(
                    targetConnection,
                    "SELECT encode(raw_value, 'hex')::text FROM orders WHERE label = 'first'"
                )
                let payload = try await scalarString(
                    targetConnection,
                    "SELECT payload::text FROM orders WHERE label = 'first'"
                )
                let tags = try await scalarString(
                    targetConnection,
                    "SELECT tags::text FROM orders WHERE label = 'first'"
                )
                let doubled = try await scalarString(
                    targetConnection,
                    "SELECT doubled::text FROM orders WHERE label = 'first'"
                )
                #expect(customerCount == 2)
                #expect(orderCount == 2)
                #expect(orphanCount == 0)
                #expect(email == "nyvpr@rknzcyr.pbz")
                #expect(bytea == "00090a5c")
                #expect(payload == #"{"line": "one\tand\ntwo"}"#)
                #expect(tags == "{alpha,\"with space\"}")
                #expect(doubled == "25.00")

                try await execute(
                    targetConnection,
                    """
                    INSERT INTO customers(id, email, display_name)
                    OVERRIDING SYSTEM VALUE
                    VALUES (99, 'keep@example.com', 'Target only')
                    """
                )
            }

            try await withConnection(source, password: password, id: 32) { sourceConnection in
                try await execute(
                    sourceConnection,
                    "UPDATE customers SET display_name = 'Updated source' WHERE id = 1"
                )
            }

            var upsertRequest = request
            upsertRequest.options.skipStructure = true
            upsertRequest.options.conflictMode = .replace
            upsertRequest.options.transformations = [:]
            let second = try await runClone(
                coordinator: coordinator,
                request: upsertRequest,
                source: source,
                target: target
            )
            #expect(second.result.isCompleteSuccess)

            try await withConnection(target, password: password, id: 33) { verification in
                let name = try await scalarString(
                    verification,
                    "SELECT display_name::text FROM customers WHERE id = 1"
                )
                let retained = try await scalarInt(
                    verification,
                    "SELECT count(*)::bigint FROM customers WHERE id = 99"
                )
                #expect(name == "Updated source")
                #expect(retained == 1)
            }
        }
    }

    @Test("A COPY failure rolls back the current table")
    func rollbackCurrentTable() async throws {
        let configuration = try #require(integrationConfiguration)
        try await configuration.withDatabases { source, target, password in
            try await withConnection(source, password: password, id: 41) { sourceConnection in
                try await execute(
                    sourceConnection,
                    """
                    CREATE TABLE public.identifiers (
                      id uuid PRIMARY KEY,
                      label text NOT NULL
                    )
                    """
                )
                try await execute(
                    sourceConnection,
                    """
                    INSERT INTO public.identifiers VALUES
                      ('12345678-1234-1234-1234-1234567890ab', 'will fail')
                    """
                )
            }

            let request = CloneRequest(
                sourceProfileID: source.id,
                targetProfileID: target.id,
                selectedTables: [TableReference(name: "identifiers")],
                options: CopyOptions(
                    limit: 10,
                    transformations: ["public.identifiers.id": .rot13]
                )
            )
            let output = try await runClone(
                coordinator: coordinator(password: password),
                request: request,
                source: source,
                target: target
            )
            #expect(!output.result.isCompleteSuccess)
            if case .rolledBack = output.result.outcomes[TableReference(name: "identifiers")] {
                // Expected.
            } else {
                Issue.record("The failed table was not reported as rolled back.")
            }

            try await withConnection(target, password: password, id: 42) { verification in
                let table = try await scalarString(
                    verification,
                    "SELECT to_regclass('public.identifiers')::text"
                )
                #expect(table == nil)
            }
        }
    }

    @Test("Cancellation rolls back the active table")
    func cancellation() async throws {
        let configuration = try #require(integrationConfiguration)
        try await configuration.withDatabases { source, target, password in
            try await withConnection(source, password: password, id: 51) { sourceConnection in
                try await execute(
                    sourceConnection,
                    """
                    CREATE TABLE public.large_rows (
                      id bigint PRIMARY KEY,
                      payload text NOT NULL
                    )
                    """
                )
                try await execute(
                    sourceConnection,
                    """
                    INSERT INTO public.large_rows
                    SELECT value, repeat(md5(value::text), 4)
                    FROM generate_series(1, 150000) value
                    """
                )
            }

            let coordinator = coordinator(password: password)
            let request = CloneRequest(
                sourceProfileID: source.id,
                targetProfileID: target.id,
                selectedTables: [TableReference(name: "large_rows")],
                options: CopyOptions(limit: 150_000)
            )

            let stream = try await coordinator.start(
                request: request,
                sourceProfile: source,
                targetProfile: target
            )
            var result: CloneResult?
            var requestedCancellation = false
            for await event in stream {
                if case let .progress(progress) = event,
                   progress.table == TableReference(name: "large_rows"),
                   progress.phase == .copying,
                   progress.rowsCopied > 0,
                   !requestedCancellation
                {
                    requestedCancellation = true
                    await coordinator.cancel()
                }
                if case let .finished(value) = event {
                    result = value
                }
            }

            let completed = try #require(result)
            #expect(requestedCancellation)
            #expect(completed.wasCancelled)
            try await withConnection(target, password: password, id: 52) { verification in
                let table = try await scalarString(
                    verification,
                    "SELECT to_regclass('public.large_rows')::text"
                )
                #expect(table == nil)
            }
        }
    }
}

private struct IntegrationConfiguration: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let maintenanceDatabase: String

    static func fromEnvironment() -> Self? {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["PGCLONER_TEST_PORT"],
              let port = Int(portText)
        else {
            return nil
        }
        return Self(
            host: environment["PGCLONER_TEST_HOST"] ?? "127.0.0.1",
            port: port,
            username: environment["PGCLONER_TEST_USER"] ?? "postgres",
            password: environment["PGCLONER_TEST_PASSWORD"] ?? "pgcloner",
            maintenanceDatabase: environment["PGCLONER_TEST_DATABASE"] ?? "postgres"
        )
    }

    func withDatabases(
        _ body: (ConnectionProfile, ConnectionProfile, String) async throws -> Void
    ) async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sourceDatabase = "pgcloner_source_\(suffix)"
        let targetDatabase = "pgcloner_target_\(suffix)"
        let administration = profile(database: maintenanceDatabase, name: "Administration")
        try await withConnection(administration, password: password, id: 10) { connection in
            try await execute(connection, "CREATE DATABASE \(SQLIdentifier.quote(sourceDatabase))")
            do {
                try await execute(connection, "CREATE DATABASE \(SQLIdentifier.quote(targetDatabase))")
            } catch {
                try? await execute(connection, "DROP DATABASE \(SQLIdentifier.quote(sourceDatabase))")
                throw error
            }
        }

        let source = profile(database: sourceDatabase, name: "Source")
        let target = profile(database: targetDatabase, name: "Target")
        do {
            try await body(source, target, password)
        } catch {
            try? await dropDatabases(sourceDatabase, targetDatabase)
            throw error
        }
        try await dropDatabases(sourceDatabase, targetDatabase)
    }

    private func dropDatabases(_ source: String, _ target: String) async throws {
        let administration = profile(database: maintenanceDatabase, name: "Administration")
        try await withConnection(administration, password: password, id: 11) { connection in
            for database in [source, target] {
                try await execute(
                    connection,
                    """
                    SELECT pg_terminate_backend(pid)
                    FROM pg_stat_activity
                    WHERE datname = \(SQLIdentifier.literal(database))
                      AND pid <> pg_backend_pid()
                    """
                )
                try await execute(
                    connection,
                    "DROP DATABASE IF EXISTS \(SQLIdentifier.quote(database))"
                )
            }
        }
    }

    private func profile(database: String, name: String) -> ConnectionProfile {
        ConnectionProfile(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            tlsMode: .disable
        )
    }
}

private struct CloneOutput {
    let plan: ClonePlan
    let result: CloneResult
}

private func coordinator(password: String) -> CloneCoordinator {
    CloneCoordinator(
        credentials: ClosureCredentialProvider { _ in password },
        logger: Logger(label: "PGCloner.Integration")
    )
}

private func runClone(
    coordinator: CloneCoordinator,
    request: CloneRequest,
    source: ConnectionProfile,
    target: ConnectionProfile
) async throws -> CloneOutput {
    let stream = try await coordinator.start(
        request: request,
        sourceProfile: source,
        targetProfile: target
    )
    var plan: ClonePlan?
    var result: CloneResult?
    for await event in stream {
        switch event {
        case let .started(value): plan = value
        case let .finished(value): result = value
        case .progress, .log: break
        }
    }
    return CloneOutput(
        plan: try #require(plan),
        result: try #require(result)
    )
}

private func connect(
    _ profile: ConnectionProfile,
    password: String,
    id: Int
) async throws -> PostgresConnection {
    try await PostgresConnectionFactory(
        logger: Logger(label: "PGCloner.Integration.Connection")
    ).connect(profile: profile, password: password, connectionID: id)
}

private func withConnection<Result>(
    _ profile: ConnectionProfile,
    password: String,
    id: Int,
    _ body: (PostgresConnection) async throws -> Result
) async throws -> Result {
    let connection = try await connect(profile, password: password, id: id)
    do {
        let result = try await body(connection)
        try await connection.closeGracefully()
        return result
    } catch {
        try? await connection.closeGracefully()
        throw error
    }
}

private func execute(_ connection: PostgresConnection, _ sql: String) async throws {
    do {
        let rows = try await connection.query(
            PostgresQuery(unsafeSQL: sql),
            logger: Logger(label: "PGCloner.Integration.Query")
        )
        for try await _ in rows {}
    } catch {
        throw IntegrationTestError.query(String(reflecting: error))
    }
}

private func scalarString(
    _ connection: PostgresConnection,
    _ sql: String
) async throws -> String? {
    let rows = try await connection.query(
        PostgresQuery(unsafeSQL: sql),
        logger: Logger(label: "PGCloner.Integration.Query")
    )
    for try await row in rows {
        return try Array(row)[0].decode(String?.self)
    }
    return nil
}

private func scalarInt(
    _ connection: PostgresConnection,
    _ sql: String
) async throws -> Int64? {
    let rows = try await connection.query(
        PostgresQuery(unsafeSQL: sql),
        logger: Logger(label: "PGCloner.Integration.Query")
    )
    for try await row in rows {
        return try Array(row)[0].decode(Int64?.self)
    }
    return nil
}

private func prepareRepresentativeSource(
    _ profile: ConnectionProfile,
    password: String
) async throws {
    try await withConnection(profile, password: password, id: 20) { connection in
        try await execute(
            connection,
            """
            CREATE TABLE public.customers (
              id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              email text NOT NULL,
              display_name text
            )
            """
        )
        try await execute(
            connection,
            """
            CREATE TABLE public.orders (
              id uuid PRIMARY KEY,
              customer_id bigint NOT NULL REFERENCES public.customers(id),
              status text NOT NULL,
              label text NOT NULL,
              payload jsonb NOT NULL,
              tags text[] NOT NULL,
              amount numeric(12,2) NOT NULL,
              doubled numeric GENERATED ALWAYS AS (amount * 2) STORED,
              raw_value bytea,
              optional_note text
            )
            """
        )
        try await execute(
            connection,
            "CREATE INDEX orders_status_idx ON public.orders(status)"
        )
        try await execute(
            connection,
            #"""
            INSERT INTO public.customers(email, display_name) VALUES
              ('alice@example.com', E'Alice\nExample'),
              ('bob@example.com', 'Bob'),
              ('unused@example.com', 'Unused')
            """#
        )
        try await execute(
            connection,
            #"""
            INSERT INTO public.orders(
              id, customer_id, status, label, payload, tags, amount, raw_value, optional_note
            ) VALUES
              (
                '10000000-0000-0000-0000-000000000001',
                1,
                'active',
                'first',
                '{"line":"one\tand\ntwo"}',
                ARRAY['alpha', 'with space'],
                12.50,
                decode('00090a5c', 'hex'),
                NULL
              ),
              (
                '10000000-0000-0000-0000-000000000002',
                2,
                'active',
                'second',
                '{"number":2}',
                ARRAY['beta'],
                25.10,
                decode('ff', 'hex'),
                E'tab\tnewline\nslash\\'
              ),
              (
                '10000000-0000-0000-0000-000000000003',
                3,
                'archived',
                'excluded',
                '{}',
                ARRAY[]::text[],
                1.00,
                NULL,
                NULL
              )
            """#
        )
    }
}

private enum IntegrationTestError: Error, CustomStringConvertible {
    case query(String)

    var description: String {
        switch self {
        case let .query(message): message
        }
    }
}
