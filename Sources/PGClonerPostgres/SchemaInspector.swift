import Foundation
import Logging
import PGClonerCore
import PostgresNIO

public struct SchemaInspector: Sendable {
    private let query: PostgresQuerySupport

    public init(connection: PostgresConnection, logger: Logger = Logger(label: "PGCloner.Inspector")) {
        self.query = PostgresQuerySupport(connection: connection, logger: logger)
    }

    public func schemas() async throws -> [String] {
        let rows = try await query.rows("""
            SELECT schema_name::text
            FROM information_schema.schemata
            WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
            ORDER BY schema_name
            """)
        return try rows.map { try Array($0).requiredString(0, field: "schema name") }
    }

    public func tables(in schema: String) async throws -> [TableSummary] {
        let sql: PostgresQuery = """
            SELECT
              t.table_name::text,
              COALESCE(c.reltuples::bigint, 0),
              COALESCE(fk.fk_count, 0)::bigint
            FROM information_schema.tables t
            LEFT JOIN pg_namespace n ON n.nspname = t.table_schema
            LEFT JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = t.table_name
            LEFT JOIN LATERAL (
              SELECT count(*)::bigint AS fk_count
              FROM pg_constraint con
              WHERE con.conrelid = c.oid AND con.contype = 'f'
            ) fk ON true
            WHERE t.table_schema = \(schema)
              AND t.table_type = 'BASE TABLE'
            ORDER BY t.table_name
            """

        return try await query.rows(sql).map { row in
            let cells = Array(row)
            return TableSummary(
                reference: TableReference(
                    schema: schema,
                    name: try cells.requiredString(0, field: "table name")
                ),
                estimatedRows: try cells.int64(1),
                foreignKeyCount: Int(try cells.int64(2))
            )
        }
    }

    public func allForeignKeys() async throws -> [ForeignKeyMetadata] {
        let rows = try await query.rows("""
            SELECT
              con.conname::text,
              child_ns.nspname::text,
              child.relname::text,
              parent_ns.nspname::text,
              parent.relname::text,
              ARRAY(
                SELECT att.attname::text
                FROM unnest(con.conkey) WITH ORDINALITY AS key(attnum, ord)
                JOIN pg_attribute att
                  ON att.attrelid = con.conrelid AND att.attnum = key.attnum
                ORDER BY key.ord
              ),
              ARRAY(
                SELECT att.attname::text
                FROM unnest(con.confkey) WITH ORDINALITY AS key(attnum, ord)
                JOIN pg_attribute att
                  ON att.attrelid = con.confrelid AND att.attnum = key.attnum
                ORDER BY key.ord
              ),
              pg_get_constraintdef(con.oid)::text
            FROM pg_constraint con
            JOIN pg_class child ON child.oid = con.conrelid
            JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
            JOIN pg_class parent ON parent.oid = con.confrelid
            JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
            WHERE con.contype = 'f'
              AND child_ns.nspname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY child_ns.nspname, child.relname, con.conname
            """)

        return try rows.map { row in
            let cells = Array(row)
            return ForeignKeyMetadata(
                name: try cells.requiredString(0, field: "foreign key name"),
                childTable: TableReference(
                    schema: try cells.requiredString(1, field: "child schema"),
                    name: try cells.requiredString(2, field: "child table")
                ),
                parentTable: TableReference(
                    schema: try cells.requiredString(3, field: "parent schema"),
                    name: try cells.requiredString(4, field: "parent table")
                ),
                childColumns: try cells.strings(5),
                parentColumns: try cells.strings(6),
                definition: try cells.string(7)
            )
        }
    }

    public func metadata(
        for table: TableReference,
        knownForeignKeys: [ForeignKeyMetadata]? = nil
    ) async throws -> TableMetadata {
        // A Postgres connection owns one protocol stream. Keeping catalog reads
        // sequential avoids overlapping row sequences on the same connection.
        let columns = try await columns(for: table)
        let primaryKey = try await primaryKey(for: table)
        let tableForeignKeys: [ForeignKeyMetadata]
        if let knownForeignKeys {
            tableForeignKeys = knownForeignKeys.filter { $0.childTable == table }
        } else {
            tableForeignKeys = try await foreignKeys(for: table)
        }
        let indexes = try await indexes(for: table)
        let sequences = try await sequences(for: table)

        return TableMetadata(
            reference: table,
            columns: columns,
            primaryKey: primaryKey,
            foreignKeys: tableForeignKeys,
            indexes: indexes,
            sequences: sequences
        )
    }

    public func customTypes(for tables: [TableReference]) async throws -> [String] {
        guard !tables.isEmpty else { return [] }
        let names = tables.map(SQLIdentifier.quote)
        let rows = try await query.rows(
            """
            SELECT DISTINCT format('%I.%I', type_ns.nspname, typ.typname)::text
            FROM pg_attribute att
            JOIN pg_type typ ON typ.oid = att.atttypid
            JOIN pg_namespace type_ns ON type_ns.oid = typ.typnamespace
            WHERE att.attrelid IN (
              SELECT unnest($1::text[])::regclass
            )
              AND att.attnum > 0
              AND NOT att.attisdropped
              AND type_ns.nspname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY 1
            """,
            textArrayBindings: [names]
        )
        return try rows.map { try Array($0).requiredString(0, field: "type name") }
    }

    public func columns(for table: TableReference) async throws -> [ColumnMetadata] {
        let tableName = SQLIdentifier.quote(table)
        let sql: PostgresQuery = """
            SELECT
              att.attname::text,
              pg_catalog.format_type(att.atttypid, att.atttypmod)::text,
              NOT att.attnotnull,
              CASE WHEN att.attgenerated = '' THEN pg_get_expr(def.adbin, def.adrelid) END::text,
              CASE WHEN att.attgenerated <> '' THEN pg_get_expr(def.adbin, def.adrelid) END::text,
              att.attidentity::text
            FROM pg_attribute att
            LEFT JOIN pg_attrdef def
              ON def.adrelid = att.attrelid AND def.adnum = att.attnum
            WHERE att.attrelid = \(tableName)::regclass
              AND att.attnum > 0
              AND NOT att.attisdropped
            ORDER BY att.attnum
            """

        return try await query.rows(sql).map { row in
            let cells = Array(row)
            let identityCode = try cells.string(5)
            let identity: IdentityGeneration? = switch identityCode {
            case "a": .always
            case "d": .byDefault
            default: nil
            }
            return ColumnMetadata(
                name: try cells.requiredString(0, field: "column name"),
                typeName: try cells.requiredString(1, field: "column type"),
                isNullable: try cells.bool(2),
                defaultExpression: try cells.string(3),
                generatedExpression: try cells.string(4),
                identity: identity
            )
        }
    }

    public func primaryKey(for table: TableReference) async throws -> PrimaryKeyMetadata? {
        let tableName = SQLIdentifier.quote(table)
        let sql: PostgresQuery = """
            SELECT
              con.conname::text,
              ARRAY(
                SELECT att.attname::text
                FROM unnest(con.conkey) WITH ORDINALITY AS key(attnum, ord)
                JOIN pg_attribute att
                  ON att.attrelid = con.conrelid AND att.attnum = key.attnum
                ORDER BY key.ord
              ),
              pg_get_constraintdef(con.oid)::text
            FROM pg_constraint con
            WHERE con.conrelid = \(tableName)::regclass AND con.contype = 'p'
            """
        guard let row = try await query.first(sql) else { return nil }
        let cells = Array(row)
        return PrimaryKeyMetadata(
            name: try cells.requiredString(0, field: "primary key name"),
            columns: try cells.strings(1),
            definition: try cells.requiredString(2, field: "primary key definition")
        )
    }

    private func foreignKeys(for table: TableReference) async throws -> [ForeignKeyMetadata] {
        try await allForeignKeys().filter { $0.childTable == table }
    }

    private func indexes(for table: TableReference) async throws -> [IndexMetadata] {
        let tableName = SQLIdentifier.quote(table)
        let sql: PostgresQuery = """
            SELECT idx.relname::text, pg_get_indexdef(idx.oid)::text
            FROM pg_index relation
            JOIN pg_class idx ON idx.oid = relation.indexrelid
            WHERE relation.indrelid = \(tableName)::regclass
              AND NOT relation.indisprimary
            ORDER BY idx.relname
            """
        return try await query.rows(sql).map { row in
            let cells = Array(row)
            return IndexMetadata(
                name: try cells.requiredString(0, field: "index name"),
                definition: try cells.requiredString(1, field: "index definition")
            )
        }
    }

    private func sequences(for table: TableReference) async throws -> [SequenceMetadata] {
        let qualified = SQLIdentifier.quote(table)
        let sql: PostgresQuery = """
            SELECT
              cols.column_name::text,
              pg_get_serial_sequence(\(qualified), cols.column_name)::text
            FROM information_schema.columns cols
            WHERE cols.table_schema = \(table.schema)
              AND cols.table_name = \(table.name)
            ORDER BY cols.ordinal_position
            """
        return try await query.rows(sql).compactMap { row in
            let cells = Array(row)
            guard let sequence = try cells.string(1) else { return nil }
            return SequenceMetadata(
                column: try cells.requiredString(0, field: "sequence column"),
                qualifiedSequenceName: sequence
            )
        }
    }
}
