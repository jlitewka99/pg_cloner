import Foundation
import Logging
import PGClonerCore
import PostgresNIO

struct PostgresQuerySupport: Sendable {
    let connection: PostgresConnection
    let logger: Logger

    init(connection: PostgresConnection, logger: Logger) {
        self.connection = connection
        self.logger = logger
    }

    @discardableResult
    func execute(_ query: PostgresQuery) async throws -> Int {
        let rows = try await connection.query(query, logger: logger)
        var consumed = 0
        for try await _ in rows {
            consumed += 1
        }
        return consumed
    }

    @discardableResult
    func execute(_ sql: String) async throws -> Int {
        try await execute(PostgresQuery(unsafeSQL: sql))
    }

    func rows(_ query: PostgresQuery) async throws -> [PostgresRow] {
        let sequence = try await connection.query(query, logger: logger)
        var output: [PostgresRow] = []
        for try await row in sequence {
            output.append(row)
        }
        return output
    }

    func rows(_ sql: String, textArrayBindings: [[String]] = []) async throws -> [PostgresRow] {
        try await rows(Self.query(sql, textArrayBindings: textArrayBindings))
    }

    func first(_ query: PostgresQuery) async throws -> PostgresRow? {
        let sequence = try await connection.query(query, logger: logger)
        var iterator = sequence.makeAsyncIterator()
        return try await iterator.next()
    }

    func scalarString(_ query: PostgresQuery) async throws -> String? {
        guard let row = try await first(query), let cell = Array(row).first else { return nil }
        return try cell.decode(String?.self)
    }

    func scalarInt64(_ query: PostgresQuery) async throws -> Int64? {
        guard let row = try await first(query), let cell = Array(row).first else { return nil }
        return try cell.decode(Int64?.self)
    }

    static func query(_ sql: String, textArrayBindings: [[String]]) throws -> PostgresQuery {
        var bindings = PostgresBindings(capacity: textArrayBindings.count)
        for values in textArrayBindings {
            bindings.append(values)
        }
        return PostgresQuery(unsafeSQL: sql, binds: bindings)
    }
}

extension Array where Element == PostgresCell {
    func string(_ index: Int) throws -> String? {
        try self[index].decode(String?.self)
    }

    func requiredString(_ index: Int, field: String) throws -> String {
        guard let value = try string(index) else {
            throw CloneEngineError.invalidMetadata("Missing \(field).")
        }
        return value
    }

    func int64(_ index: Int) throws -> Int64 {
        try self[index].decode(Int64.self)
    }

    func bool(_ index: Int) throws -> Bool {
        try self[index].decode(Bool.self)
    }

    func strings(_ index: Int) throws -> [String] {
        try self[index].decode([String].self)
    }
}
