import Foundation
import Testing
@testable import PGClonerCore

@Suite("Transformations, COPY text, and DDL")
struct TransformationAndDDLTests {
    @Test("Transformations use column indexes even when values repeat")
    func transformationUsesColumnPosition() throws {
        let columns = [
            ColumnMetadata(name: "email", typeName: "text", isNullable: true),
            ColumnMetadata(name: "phone", typeName: "text", isNullable: true)
        ]

        let row = try TransformationEngine().transform(
            row: ["same", "same"],
            columns: columns,
            transformations: ["phone": .reverse]
        )

        #expect(row == ["same", "emas"])
    }

    @Test("ROT13 and Add100 preserve expected values")
    func strategyValues() {
        let engine = TransformationEngine()
        #expect(engine.apply(.rot13, to: "Alice@example.com") == "Nyvpr@rknzcyr.pbz")
        #expect(engine.apply(.add100, to: "12.50") == "112.5")
        #expect(engine.apply(.add100, to: "0") == "0")
        #expect(engine.apply(.add100, to: "not-a-number") == "not-a-number")
    }

    @Test("Qualified UI choices override a generic column strategy")
    func qualifiedTransformationWins() throws {
        let table = TableReference(schema: "sales", name: "customers")
        let row = try TransformationEngine().transform(
            row: ["Alice"],
            columns: [ColumnMetadata(name: "name", typeName: "text", isNullable: false)],
            transformations: [
                "name": .reverse,
                "sales.customers.name": .rot13
            ],
            table: table
        )

        #expect(row == ["Nyvpr"])
    }

    @Test("Local transformation patterns take priority over defaults")
    func localRulePriority() {
        let defaults = TransformationRuleSet(
            columnPatterns: [
                .init(pattern: "(?i)email", strategy: .rot13)
            ]
        )
        let local = TransformationRuleSet(
            columnPatterns: [
                .init(pattern: "(?i)work_email", strategy: .reverse)
            ]
        )
        let merged = local.merged(over: defaults)
        let result = merged.transformations(
            for: TableReference(name: "people"),
            columns: [
                ColumnMetadata(name: "work_email", typeName: "text", isNullable: true)
            ]
        )

        #expect(result["work_email"] == .reverse)
    }

    @Test("An explicit null table rule disables a matching default pattern")
    func explicitNullRuleDisablesPattern() throws {
        let rules = try TransformationRuleLoader.bundledDefaults()
        let result = rules.transformations(
            for: TableReference(name: "dim_customer"),
            columns: [
                ColumnMetadata(
                    name: "customer_category",
                    typeName: "text",
                    isNullable: true
                ),
                ColumnMetadata(
                    name: "customer_name",
                    typeName: "text",
                    isNullable: true
                )
            ]
        )

        #expect(result["customer_category"] == nil)
        #expect(result["customer_name"] == .rot13)
    }

    @Test("COPY text escapes delimiters, newlines, slashes, and null")
    func copyEncoding() {
        let data = CopyTextEncoder().encode(row: [
            nil,
            "a\tb",
            "line\nnext",
            #"c:\tmp"#
        ])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == "\\N\ta\\tb\tline\\nnext\tc:\\\\tmp\n")
    }

    @Test("Identifiers safely quote embedded quotes")
    func identifierQuoting() {
        #expect(SQLIdentifier.quote(#"a"b"#) == #""a""b""#)
        #expect(
            SQLIdentifier.quote(TableReference(schema: "odd schema", name: "table"))
                == #""odd schema"."table""#
        )
    }

    @Test("DDL includes identity, generated columns, defaults, and primary key")
    func ddlGeneration() throws {
        let table = TableReference(schema: "app", name: "orders")
        let metadata = TableMetadata(
            reference: table,
            columns: [
                ColumnMetadata(
                    name: "id",
                    typeName: "bigint",
                    isNullable: false,
                    identity: .always
                ),
                ColumnMetadata(
                    name: "amount",
                    typeName: "numeric(12,2)",
                    isNullable: false,
                    defaultExpression: "0"
                ),
                ColumnMetadata(
                    name: "gross",
                    typeName: "numeric",
                    isNullable: true,
                    generatedExpression: "amount * 1.23"
                )
            ],
            primaryKey: PrimaryKeyMetadata(
                name: "orders_pkey",
                columns: ["id"],
                definition: "PRIMARY KEY (id)"
            )
        )

        let sql = try DDLGenerator().createTable(metadata)
        #expect(sql.contains(#""id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL"#))
        #expect(sql.contains(#""amount" numeric(12,2) DEFAULT 0 NOT NULL"#))
        #expect(sql.contains(#""gross" numeric GENERATED ALWAYS AS (amount * 1.23) STORED"#))
        #expect(sql.contains(#"CONSTRAINT "orders_pkey" PRIMARY KEY (id)"#))
    }

    @Test("Filter safety remains enabled by default")
    func validatesSafety() {
        #expect(throws: CloneEngineError.self) {
            _ = try CopyOptions().validated()
        }
        #expect(throws: Never.self) {
            _ = try CopyOptions(limit: 100).validated()
        }
    }

    @Test("Upsert overrides identity inserts but never updates GENERATED ALWAYS identity")
    func upsertIdentityHandling() throws {
        let sql = try UpsertSQLBuilder().statement(
            target: TableReference(schema: "app", name: "accounts"),
            stageTable: "stage",
            columns: [
                ColumnMetadata(
                    name: "id",
                    typeName: "bigint",
                    isNullable: false,
                    identity: .always
                ),
                ColumnMetadata(name: "external_key", typeName: "uuid", isNullable: false),
                ColumnMetadata(name: "payload", typeName: "jsonb", isNullable: true)
            ],
            primaryKey: PrimaryKeyMetadata(
                name: "accounts_pkey",
                columns: ["external_key"],
                definition: "PRIMARY KEY (external_key)"
            )
        )

        #expect(sql.contains("OVERRIDING SYSTEM VALUE"))
        #expect(sql.contains(#""payload" = EXCLUDED."payload""#))
        #expect(!sql.contains(#""id" = EXCLUDED."id""#))
    }

    @Test("Upsert can project safe staging aliases into quoted target columns")
    func upsertStageAliases() throws {
        let sql = try UpsertSQLBuilder().statement(
            target: TableReference(schema: "odd", name: #"a"b"#),
            stageTable: "stage",
            columns: [
                ColumnMetadata(name: #"i"d"#, typeName: "uuid", isNullable: false),
                ColumnMetadata(name: "value", typeName: "text", isNullable: true)
            ],
            stageColumnNames: ["pgcloner_c0", "pgcloner_c1"],
            primaryKey: PrimaryKeyMetadata(
                name: "key",
                columns: [#"i"d"#],
                definition: #"PRIMARY KEY ("i""d")"#
            )
        )

        #expect(sql.contains(#"INSERT INTO "odd"."a""b" ("i""d", "value")"#))
        #expect(sql.contains(#"SELECT "pgcloner_c0", "pgcloner_c1" FROM "stage""#))
    }
}
